#!/usr/bin/env python3
"""usage: guard_tree.py MAX_MB MAX_SECONDS COMMAND...   (kills the whole process tree when over a limit)

Like Tools/Experiments/LongLineSplit/guarded.sh, but adds up the memory of every descendant: a
build spawns compilers, and the parent alone says nothing about an 8 GB machine running out.
"""
import os, signal, subprocess, sys, time

def tree_rss_mb(root):
    out = subprocess.run(["ps", "-ax", "-o", "pid=,ppid=,rss="], capture_output=True, text=True).stdout
    rows = [tuple(map(int, l.split())) for l in out.splitlines() if l.strip()]
    children = {}
    for pid, ppid, rss in rows:
        children.setdefault(ppid, []).append((pid, rss))
    total, stack, pids = 0, [root], []
    rss_of = {pid: rss for pid, _, rss in rows}
    while stack:
        p = stack.pop()
        pids.append(p)
        total += rss_of.get(p, 0)
        stack.extend(c for c, _ in children.get(p, []))
    return total / 1024, pids

limit_mb, limit_s = float(sys.argv[1]), float(sys.argv[2])
proc = subprocess.Popen(sys.argv[3:], start_new_session=True)
start, peak = time.time(), 0
while proc.poll() is None:
    mb, pids = tree_rss_mb(proc.pid)
    peak = max(peak, mb)
    if mb > limit_mb or time.time() - start > limit_s:
        for p in pids:
            try: os.kill(p, signal.SIGKILL)
            except ProcessLookupError: pass
        print(f"GUARD: killed at {mb:.0f} MB after {time.time()-start:.0f}s (limits {limit_mb:.0f} MB / {limit_s:.0f}s)")
        sys.exit(99)
    time.sleep(0.5)
print(f"GUARD: exit={proc.returncode} peak={peak:.0f} MB in {time.time()-start:.0f}s")
sys.exit(proc.returncode)
