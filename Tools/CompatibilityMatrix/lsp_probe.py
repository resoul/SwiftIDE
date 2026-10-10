#!/usr/bin/env python3
"""Asks SourceKit-LSP the same questions about a fixture and records what it answers (TK-009).

Usage: lsp_probe.py CASE.json [--server PATH] [--phase NAME] [--restart] [--out FILE]

A case file describes one fixture:
{
  "name": "swiftpm",
  "root": "../../Fixtures/SwiftPMPackage",           # relative to the case file
  "document": "Sources/App/main.swift",               # the file the questions are about
  "edit": {"append": "\\nlet number: Int = greeter.greeting()\\n"},   # unsaved text added in memory
  "diagnostics": [{"expect": "cannot convert"}, {"expect": "configuration probe", "present": false}],
  "questions": [
    {"kind": "hover", "needle": "greeter.greeting", "offset": 8, "expect": "greeting"},
    {"kind": "definition", "needle": "greeter.greeting", "offset": 8, "expect_file": "Greeter.swift"},
    {"kind": "completion", "after": "greeter.", "expect": "greeting"}
  ],
  "initialization_options": {}
}

Every answer is judged by a substring of the answer, not by its exact shape. The output is JSON:
for each question: ok, the elapsed seconds, and a short excerpt of what came back.
"""
import argparse
import json
import os
import queue
import subprocess
import sys
import threading
import time
from pathlib import Path


class Client:
    def __init__(self, command, cwd, env=None):
        self.proc = subprocess.Popen(
            command, cwd=cwd, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE
        )
        self.next_id = 1
        self.pending = {}
        self.notifications = queue.Queue()
        self.diagnostics = {}
        self.log = []
        self.lock = threading.Lock()
        self.stderr_lines = []
        threading.Thread(target=self._read_loop, daemon=True).start()
        threading.Thread(target=self._stderr_loop, daemon=True).start()

    def _stderr_loop(self):
        for line in self.proc.stderr:
            self.stderr_lines.append(line.decode("utf-8", "replace").rstrip())
            del self.stderr_lines[:-200]

    def _read_message(self):
        headers = {}
        while True:
            line = self.proc.stdout.readline()
            if not line:
                return None
            line = line.decode("ascii", "replace").strip()
            if not line:
                break
            key, _, value = line.partition(":")
            headers[key.lower()] = value.strip()
        length = int(headers.get("content-length", "0"))
        body = self.proc.stdout.read(length)
        return json.loads(body.decode("utf-8"))

    def _read_loop(self):
        while True:
            message = self._read_message()
            if message is None:
                break
            if "method" in message and "id" in message:
                # A request from the server: answer politely with null.
                self._send({"jsonrpc": "2.0", "id": message["id"], "result": None})
            elif "method" in message:
                if message["method"] == "textDocument/publishDiagnostics":
                    params = message["params"]
                    with self.lock:
                        self.diagnostics[params["uri"]] = params["diagnostics"]
                self.notifications.put(message)
            elif "id" in message:
                with self.lock:
                    slot = self.pending.pop(message["id"], None)
                if slot:
                    slot["message"] = message
                    slot["event"].set()

    def _send(self, payload):
        data = json.dumps(payload).encode("utf-8")
        self.proc.stdin.write(b"Content-Length: %d\r\n\r\n" % len(data) + data)
        self.proc.stdin.flush()

    def request(self, method, params, timeout=60):
        with self.lock:
            request_id = self.next_id
            self.next_id += 1
            slot = {"event": threading.Event(), "message": None}
            self.pending[request_id] = slot
        self._send({"jsonrpc": "2.0", "id": request_id, "method": method, "params": params})
        if not slot["event"].wait(timeout):
            return {"error": {"message": f"timeout after {timeout}s"}}
        return slot["message"]

    def notify(self, method, params):
        self._send({"jsonrpc": "2.0", "method": method, "params": params})

    def close(self):
        try:
            self.request("shutdown", None, timeout=10)
            self.notify("exit", None)
            self.proc.wait(timeout=10)
        except Exception:
            self.proc.kill()


def position_of(text, needle, offset):
    index = text.index(needle) + offset
    line = text.count("\n", 0, index)
    column = len(text[text.rfind("\n", 0, index) + 1 : index].encode("utf-16-le")) // 2
    return {"line": line, "character": column}


def excerpt(value, limit=300):
    text = json.dumps(value, ensure_ascii=False)
    return text if len(text) <= limit else text[:limit] + "…"


def run(case_path, server, phase, out, restarts, timeout, overrides=()):
    case = json.loads(Path(case_path).read_text())
    for override in overrides:
        name, _, value = override.partition("=")
        for d in case.get("diagnostics", []):
            if d["expect"] == name:
                d["present"] = value.lower() == "true"
    base = Path(case_path).resolve().parent
    root = (base / case["root"]).resolve()
    document = root / case["document"]
    original = document.read_text()
    text = original + case.get("edit", {}).get("append", "")
    uri = document.as_uri()
    result = {"case": case["name"], "phase": phase, "server": server, "root": str(root), "questions": {}}

    command = [server] + case.get("server_arguments", [])
    environment = dict(os.environ)
    environment.update(case.get("environment", {}))

    for attempt in range(restarts + 1):
        started = time.time()
        client = Client(command, cwd=str(root), env=environment)
        init = client.request(
            "initialize",
            {
                "processId": os.getpid(),
                "rootUri": root.as_uri(),
                "workspaceFolders": [{"uri": root.as_uri(), "name": root.name}],
                "capabilities": {
                    "textDocument": {
                        "publishDiagnostics": {},
                        "hover": {"contentFormat": ["plaintext", "markdown"]},
                        "definition": {},
                        "completion": {"completionItem": {"snippetSupport": False}},
                    },
                    "window": {"workDoneProgress": True},
                },
                "initializationOptions": case.get("initialization_options", {}),
            },
            timeout=timeout,
        )
        result["initialize_seconds"] = round(time.time() - started, 3)
        if "error" in init:
            result["initialize_error"] = init["error"]
            client.close()
            break
        client.notify("initialized", {})
        client.notify(
            "textDocument/didOpen",
            {"textDocument": {"uri": uri, "languageId": "swift", "version": 1, "text": text}},
        )

        questions = {}

        def ask(name, ok, seconds, answer):
            questions[name] = {"ok": bool(ok), "seconds": round(seconds, 3), "answer": excerpt(answer)}

        # Diagnostics arrive when the server has a compile context. Those expected to be present
        # are waited for; those expected to be absent are checked after a grace period, and only
        # count if every present one did arrive (otherwise there was no context to judge by).
        diagnostics = case.get("diagnostics", [])
        if diagnostics:
            t0 = time.time()
            present = [d for d in diagnostics if d.get("present", True)]
            absent = [d for d in diagnostics if not d.get("present", True)]

            def messages():
                with client.lock:
                    return [i.get("message", "") for i in client.diagnostics.get(uri, [])]

            def has(d):
                return any(d["expect"].lower() in m.lower() for m in messages())

            arrival = {}
            while time.time() - t0 < timeout and not all(has(d) for d in present):
                for d in present:
                    if d["expect"] not in arrival and has(d):
                        arrival[d["expect"]] = time.time() - t0
                time.sleep(0.2)
            for d in present:
                if d["expect"] not in arrival and has(d):
                    arrival[d["expect"]] = time.time() - t0
            time.sleep(case.get("grace_seconds", 3))
            for d in present:
                ask("diagnostic: " + d["expect"], has(d), arrival.get(d["expect"], time.time() - t0), messages()[:3])
            context = all(has(d) for d in present)
            for d in absent:
                ask("no diagnostic: " + d["expect"], context and not has(d), time.time() - t0, messages()[:3])

        for question in case.get("questions", []):
            kind = question["kind"]
            label = question.get("id", kind)
            t0 = time.time()
            if kind == "hover":
                reply = client.request(
                    "textDocument/hover",
                    {"textDocument": {"uri": uri}, "position": position_of(text, question["needle"], question.get("offset", 0))},
                    timeout=timeout,
                )
                payload = reply.get("result")
                ask(label, payload and question["expect"] in json.dumps(payload), time.time() - t0, reply.get("error") or payload)
            elif kind == "definition":
                reply = client.request(
                    "textDocument/definition",
                    {"textDocument": {"uri": uri}, "position": position_of(text, question["needle"], question.get("offset", 0))},
                    timeout=timeout,
                )
                payload = reply.get("result")
                ask(label, payload and question["expect_file"] in json.dumps(payload), time.time() - t0, reply.get("error") or payload)
            elif kind == "completion":
                index = text.index(question["after"]) + len(question["after"])
                line = text.count("\n", 0, index)
                column = len(text[text.rfind("\n", 0, index) + 1 : index].encode("utf-16-le")) // 2
                reply = client.request(
                    "textDocument/completion",
                    {"textDocument": {"uri": uri}, "position": {"line": line, "character": column}},
                    timeout=timeout,
                )
                payload = reply.get("result")
                items = (payload or {}).get("items", payload if isinstance(payload, list) else [])
                labels = [i.get("label", "") for i in items]
                ask(
                    label, any(question["expect"] in item for item in labels), time.time() - t0,
                    reply.get("error") or {"count": len(labels), "first": labels[:8]},
                )

        key = "questions" if attempt == 0 else "after_restart"
        result[key] = questions
        result["stderr_tail"] = client.stderr_lines[-8:]
        client.close()

    text_out = json.dumps(result, indent=1, ensure_ascii=False)
    if out:
        Path(out).write_text(text_out + "\n")
    print(text_out)
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("case")
    parser.add_argument("--server", default=subprocess.check_output(["xcrun", "--find", "sourcekit-lsp"]).decode().strip())
    parser.add_argument("--phase", default="unspecified")
    parser.add_argument("--restart", action="store_true", help="ask everything once more after restarting the server")
    parser.add_argument("--out")
    parser.add_argument("--timeout", type=float, default=90)
    parser.add_argument("--present", action="append", default=[], help="NAME=true|false overrides whether a diagnostic is expected")
    args = parser.parse_args()
    run(args.case, args.server, args.phase, args.out, 1 if args.restart else 0, args.timeout, args.present)
