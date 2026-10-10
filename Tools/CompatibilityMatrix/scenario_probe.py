#!/usr/bin/env python3
"""Live scenarios for TK-009: what a build server does when the project changes under a running LSP.

usage: scenario_probe.py SCENARIO [--out FILE]
  new-file       a file is added to the target (project file edited) while the server runs
  config-switch  the project's default configuration is switched Release -> Debug while the server runs

Works on Fixtures/MacApp with whatever buildServer.json is there. The project is restored afterwards.
"""
import json, os, subprocess, sys, time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from lsp_probe import Client, position_of  # noqa: E402

HERE = Path(__file__).resolve().parent
FIXTURE = HERE.parent.parent / "Fixtures/MacApp"
PBX = FIXTURE / "MacApp.xcodeproj/project.pbxproj"


def regenerate(**env):
    subprocess.run([sys.executable, str(HERE / "make_xcodeproj.py")], env={**os.environ, **env}, check=True, capture_output=True)


def start(document, text):
    client = Client([subprocess.check_output(["xcrun", "--find", "sourcekit-lsp"]).decode().strip()], cwd=str(FIXTURE))
    client.request("initialize", {"processId": os.getpid(), "rootUri": FIXTURE.as_uri(),
                                   "workspaceFolders": [{"uri": FIXTURE.as_uri(), "name": "MacApp"}],
                                   "capabilities": {"textDocument": {"publishDiagnostics": {}}}}, timeout=60)
    client.notify("initialized", {})
    uri = (FIXTURE / document).as_uri()
    client.notify("textDocument/didOpen", {"textDocument": {"uri": uri, "languageId": "swift", "version": 1, "text": text}})
    return client, uri


def wait_for(client, uri, needle, timeout):
    t0 = time.time()
    while time.time() - t0 < timeout:
        with client.lock:
            if any(needle.lower() in d.get("message", "").lower() for d in client.diagnostics.get(uri, [])):
                return round(time.time() - t0, 2)
        time.sleep(0.25)
    return None


def new_file(timeout=120):
    result = {"scenario": "new-file"}
    app = (FIXTURE / "Sources/AppDelegate.swift").read_text()
    extra = FIXTURE / "Sources/Extra.swift"
    try:
        client, uri = start("Sources/AppDelegate.swift", app)
        result["baseline_appdelegate_diagnostics_seen"] = wait_for(client, uri, "cannot find", 8)  # nothing expected
        # The file appears on disk and in the target (what an IDE does when the user adds a file).
        body = 'struct Extra {\n    func answer() -> String {\n        Greeter(name: "x").greeting().count\n    }\n}\n'
        extra.write_text(body)
        regenerate(MACAPP_EXTRA="Sources/Extra.swift")
        extra_uri = extra.as_uri()
        client.notify("textDocument/didOpen", {"textDocument": {"uri": extra_uri, "languageId": "swift", "version": 1, "text": body}})
        result["seconds_until_cross_file_diagnostic_in_new_file"] = wait_for(
            client, extra_uri, "cannot convert return expression of type 'Int' to return type 'String'", timeout)
        result["stderr_tail"] = client.stderr_lines[-3:]
        client.close()
    finally:
        extra.unlink(missing_ok=True)
        regenerate()
    return result


def config_switch(timeout=120):
    result = {"scenario": "config-switch"}
    text = (FIXTURE / "Sources/AppDelegate.swift").read_text() + (
        "\n#if FLAVOUR_DEBUG\nlet debugOnly = configurationProbeDebugOnly()\n#endif\n"
        "#if FLAVOUR_RELEASE\nlet releaseOnly = configurationProbeReleaseOnly()\n#endif\n")
    try:
        client, uri = start("Sources/AppDelegate.swift", text)
        result["release_probe_before"] = wait_for(client, uri, "configurationProbeReleaseOnly", 60)
        result["debug_probe_before_switch"] = wait_for(client, uri, "configurationProbeDebugOnly", 5)
        regenerate(MACAPP_DEFAULT_CONFIG="Debug")
        t0 = time.time()
        result["seconds_until_debug_probe_after_switch"] = wait_for(client, uri, "configurationProbeDebugOnly", timeout)
        with client.lock:
            result["messages_after"] = [d["message"] for d in client.diagnostics.get(uri, [])][:4]
        client.close()
    finally:
        regenerate()
    return result


if __name__ == "__main__":
    name = sys.argv[1]
    out = sys.argv[sys.argv.index("--out") + 1] if "--out" in sys.argv else None
    result = {"new-file": new_file, "config-switch": config_switch}[name]()
    text = json.dumps(result, indent=1)
    if out:
        Path(out).write_text(text + "\n")
    print(text)
