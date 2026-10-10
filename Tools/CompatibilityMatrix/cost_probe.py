#!/usr/bin/env python3
"""Memory of the whole process tree under sourcekit-lsp, sampled while it works on a fixture.
usage: cost_probe.py CASE.json OUT.json"""
import json, os, subprocess, sys, threading, time
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parent))
from lsp_probe import Client

case = json.loads(Path(sys.argv[1]).read_text())
root = (Path(sys.argv[1]).resolve().parent / case["root"]).resolve()
doc = root / case["document"]
text = doc.read_text() + case.get("edit", {}).get("append", "")
server = subprocess.check_output(["xcrun", "--find", "sourcekit-lsp"]).decode().strip()

def tree(pid):
    rows = [tuple(map(int, l.split()[:3])) + (l.split(None, 3)[3],) for l in subprocess.run(["ps", "-ax", "-o", "pid=,ppid=,rss=,comm="], capture_output=True, text=True).stdout.splitlines() if l.strip()]
    kids, out, stack = {}, [], [pid]
    for p, pp, rss, comm in rows: kids.setdefault(pp, []).append((p, rss, comm))
    by = {p: (rss, comm) for p, pp, rss, comm in rows}
    while stack:
        p = stack.pop()
        if p in by: out.append((os.path.basename(by[p][1]), by[p][0] / 1024))
        stack.extend(c for c, _, _ in kids.get(p, []))
    return out

client = Client([server], cwd=str(root))
t0 = time.time()
client.request("initialize", {"processId": os.getpid(), "rootUri": root.as_uri(), "workspaceFolders": [{"uri": root.as_uri(), "name": root.name}],
                              "capabilities": {"textDocument": {"publishDiagnostics": {}}}}, timeout=60)
client.notify("initialized", {})
uri = doc.as_uri()
client.notify("textDocument/didOpen", {"textDocument": {"uri": uri, "languageId": "swift", "version": 1, "text": text}})
samples, first = [], None
while time.time() - t0 < 40:
    with client.lock:
        if first is None and client.diagnostics.get(uri):
            first = round(time.time() - t0, 2)
    samples.append((round(time.time() - t0, 1), tree(client.proc.pid)))
    time.sleep(1)
peak = max(samples, key=lambda s: sum(m for _, m in s[1]))
result = {"case": case["name"], "seconds_to_first_diagnostics": first,
          "peak_total_mb": round(sum(m for _, m in peak[1])),
          "peak_by_process_mb": {name: round(m) for name, m in peak[1] if m >= 20},
          "final_total_mb": round(sum(m for _, m in samples[-1][1]))}
client.close()
Path(sys.argv[2]).write_text(json.dumps(result, indent=1) + "\n")
print(json.dumps(result, indent=1))
