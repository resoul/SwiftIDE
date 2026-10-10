#!/usr/bin/env python3
"""Talks Build Server Protocol to a build server directly: usage bsp_ask.py ROOT FILE-relative-to-root"""
import json, subprocess, sys, time, urllib.parse, threading, queue
root, rel = sys.argv[1], sys.argv[2]
argv = json.load(open(root + "/buildServer.json"))["argv"]
p = subprocess.Popen(argv, cwd=root, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
replies, notes = {}, []
def reader():
    while True:
        h = {}
        while True:
            l = p.stdout.readline()
            if not l: return
            l = l.decode().strip()
            if not l: break
            k, _, v = l.partition(":"); h[k.lower()] = v.strip()
        m = json.loads(p.stdout.read(int(h["content-length"])))
        if "id" in m and "method" not in m: replies[m["id"]] = m
        else: notes.append(m)
threading.Thread(target=reader, daemon=True).start()
def send(o):
    d = json.dumps(o).encode(); p.stdin.write(b"Content-Length: %d\r\n\r\n" % len(d) + d); p.stdin.flush()
def call(i, method, params, wait=40):
    send({"jsonrpc": "2.0", "id": i, "method": method, "params": params})
    t0 = time.time()
    while i not in replies and time.time() - t0 < wait: time.sleep(0.1)
    return replies.get(i, {"error": "timeout"})
root_uri = "file://" + urllib.parse.quote(root)
print("initialize:", json.dumps(call(1, "build/initialize", {"displayName": "probe", "version": "1", "bspVersion": "2.1.0", "rootUri": root_uri, "capabilities": {"languageIds": ["swift"]}}))[:300])
send({"jsonrpc": "2.0", "method": "build/initialized", "params": {}})
time.sleep(3)
targets = call(2, "workspace/buildTargets", {})
print("targets:", json.dumps(targets)[:400])
ids = [t["id"] for t in targets.get("result", {}).get("targets", [])]
src = call(3, "buildTarget/sources", {"targets": ids})
print("sources:", json.dumps(src)[:600])
file_uri = "file://" + urllib.parse.quote(root + "/" + rel)
opts = call(4, "textDocument/sourceKitOptions", {"textDocument": {"uri": file_uri}, "target": ids[0] if ids else {"uri": ""}, "language": "swift"})
print("options:", json.dumps(opts)[:900])
p.kill()
print("stderr:", p.stderr.read().decode()[-800:])
