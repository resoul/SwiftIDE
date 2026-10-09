#!/usr/bin/env python3
"""Turns docs/benchmarks/TK-008-results.json into Markdown tables. Standard library only.

    python3 Tools/Benchmarks/summarize.py docs/benchmarks/TK-008-results.json
"""
import json
import sys


def phase(result, name, **match):
    for p in result.get("phases", []):
        if p.get("phase") == name and all(p.get(k) == v for k, v in match.items()):
            return p
    return None


def f(value, digits=1):
    if value is None:
        return "—"
    if isinstance(value, float):
        return f"{value:.{digits}f}"
    return str(value)


def size(result):
    mb = result["mb"]
    return f"{mb:g} MB" if mb >= 1 else f"{mb * 1024:.0f} KB"


def main(path):
    data = json.load(open(path))
    m = data["machine"]
    print(f"Machine: {m['chip']}, {m['memory_gb']} GB, macOS {m['os']}, run {m['date']}\n")
    results = data["results"]

    print("### Outcome\n")
    print("| Shape | Size | Lines | Finished | Wall, s | Last phase reached |")
    print("|---|---|---|---|---|---|")
    for r in results:
        fixture = phase(r, "fixture") or {}
        last = r["phases"][-1]["phase"] if r.get("phases") else "—"
        done = "skipped" if r.get("skipped") else "yes" if phase(r, "summary") else ("timeout" if r.get("timed_out") else "no")
        print(f"| {r['shape']} | {size(r)} | {f(fixture.get('lines'), 0)} | {done} | {f(r.get('wall_s'))} | {last} |")

    print("\n### Opening (read → editor → session → first layout+draw), ms\n")
    print("| Shape | Size | read | make editor | session | line index | first layout+draw | total | footprint after open, MB |")
    print("|---|---|---|---|---|---|---|---|---|")
    for r in results:
        o = phase(r, "open")
        if o:
            print(f"| {r['shape']} | {size(r)} | {f(o['read_ms'])} | {f(o['make_editor_ms'])} | {f(o['session_init_ms'])} | {f(o.get('line_index_ms'))} | {f(o['first_layout_draw_ms'])} | {f(o['total_ms'])} | {f(o['footprint_after_open_mb'], 0)} |")

    print("\n### Typing: input → commit → layout+draw, ms (60 keystrokes per place)\n")
    print("| Shape | Size | Where | n | p50 | p95 | p99 | max | commit p95 | layout+draw p95 | reconciled | caret in view |")
    print("|---|---|---|---|---|---|---|---|---|---|---|---|")
    for r in results:
        for p in r.get("phases", []):
            if p.get("phase") == "typing":
                t, c, l = p["input_to_draw"], p["native_commit"], p["layout_draw"]
                print(f"| {r['shape']} | {size(r)} | {p['where']} | {p['keystrokes_done']} | {f(t['p50_ms'])} | {f(t['p95_ms'])} | {f(t['p99_ms'])} | {f(t['max_ms'])} | {f(c['p95_ms'])} | {f(l['p95_ms'])} | {p['reconciled']} | {p.get('caret_in_view', '—')} |")

    print("\n### Building blocks (median of 3), ms\n\nBefore TK-011 a keystroke paid for the first three columns and the diff; after it, only for planning against the storage. A snapshot copies the document and is paid on save, not per keystroke.\n")
    print("| Shape | Size | backend text copy | compare equal | planner prepare | text diff | snapshot |")
    print("|---|---|---|---|---|---|---|")
    for r in results:
        p = phase(r, "primitives")
        if p:
            print(f"| {r['shape']} | {size(r)} | {f(p.get('backend_text_copy_ms'))} | {f(p.get('compare_equal_ms'))} | {f(p.get('planner_prepare_ms'), 3)} | {f(p.get('text_diff_ms'))} | {f(p.get('snapshot_ms'), 1)} |")

    print("\n### Scrolling (jump + layout+draw), ms\n")
    print("| Shape | Size | to end | to middle | to start | caret in view (end/middle/start) |")
    print("|---|---|---|---|---|---|")
    for r in results:
        p = phase(r, "scroll")
        if p:
            views = "/".join(str(p.get(f"jump_to_{k}_in_view", "—")) for k in ("end", "middle", "start"))
            print(f"| {r['shape']} | {size(r)} | {f(p['jump_to_end_ms'])} | {f(p['jump_to_middle_ms'])} | {f(p['jump_to_start_ms'])} | {views} |")

    print("\n### Margin: line numbers for the rows in view (median of 5), ms\n")
    print("| Shape | Size | lines | start | middle | end | rows labelled (start/middle/end) | 1000 lookups | index = fresh scan, rebuilds |")
    print("|---|---|---|---|---|---|---|---|---|")
    for r in results:
        p, z = phase(r, "gutter"), phase(r, "summary")
        if p:
            counts = "/".join(str(p.get(f"labels_{k}_count", "—")) for k in ("start", "middle", "end"))
            print(f"| {r['shape']} | {size(r)} | {p['line_count']} | {f(p['labels_start_ms'], 3)} | {f(p['labels_middle_ms'], 3)} | {f(p['labels_end_ms'], 3)} | {counts} | {f(p['thousand_lookups_ms'], 2)} | {(z or {}).get('line_index_matches_rescan', '—')}, {(z or {}).get('line_index_rebuilds', '—')} |")

    print("\n### Colours: refreshing what is in view, ms (typing with each approach is in the typing table)\n")
    print("Rendering attributes: a validator colours each fragment as it is laid out, refreshed with an attribute-only notification over the visible range. Storage: the same spans written into the text storage.\n")
    print("| Shape | Size | rendering start | middle | end | fragments / spans per refresh | in validator | storage start | middle | end | untouched (rendering / storage) | whole doc |")
    print("|---|---|---|---|---|---|---|---|---|---|---|---|")
    for r in results:
        p = phase(r, "attributes")
        if p:
            print(f"| {r['shape']} | {size(r)} | {f(p['rendering_refresh_start_ms'])} | {f(p['rendering_refresh_middle_ms'])} | {f(p['rendering_refresh_end_ms'])} | {p['rendering_middle_fragments']} / {p['rendering_middle_spans']} | {f(p['rendering_middle_validator_ms'], 2)} | {f(p['storage_apply_start_ms'])} | {f(p['storage_apply_middle_ms'])} | {f(p['storage_apply_end_ms'])} | {p['rendering_text_untouched']} / {p['storage_published_no_revision']} | {f(p.get('rendering_refresh_whole_ms'))} |")

    print("\n### Syntax colours (tree-sitter in the background, TK-007c)\n")
    print("Typing is measured with colours on: the keystroke (input to draw), the wait until colours of that version are on screen (lag), and the draw that shows them. Footprint is what the highlighter's text copy and syntax tree take.\n")
    print("| Shape | Size | first colours | footprint, MB | keystroke p50 / p95 | commit p95 | lag p50 / p95 | redraw p50 | main-thread refresh p95 | resyncs | spans in window |")
    print("|---|---|---|---|---|---|---|---|---|---|---|")
    for r in results:
        p = phase(r, "syntax")
        if p and "keystroke_input_to_draw" in p:
            k, c, l, d, m = (p["keystroke_input_to_draw"], p["keystroke_commit"], p["colour_lag"], p["redraw_after_colours"], p["refresh_main"])
            refresh = f(m.get("p95_ms")) if m.get("n") else "—"
            print(f"| {r['shape']} | {size(r)} | {f(p['first_colours_ms'], 0)} ms | {f(p['footprint_mb'], 0) if p['footprint_mb'] >= 0 else '—'} | {f(k['p50_ms'])} / {f(k['p95_ms'])} | {f(c['p95_ms'])} | {f(l['p50_ms'])} / {f(l['p95_ms'])} | {f(d['p50_ms'])} | {refresh} | {p['resyncs']} | {p['spans_in_window']} |")

    print("\n### Programmatic edit, undo, redo, save, ms (p50 unless noted)\n")
    print("| Shape | Size | apply | undo | redo | save #1 | save #2 | changes rebuilt = view | changes (reconciled) |")
    print("|---|---|---|---|---|---|---|---|---|")
    for r in results:
        a, u, s, z = phase(r, "programmatic_edit"), phase(r, "undo"), phase(r, "save"), phase(r, "summary")
        if a or u or s:
            replay = (z or {}).get("replay_matches_view", (u or {}).get("session_matches_view", "—"))
            counts = f"{(z or {}).get('published_changes', '—')} ({(z or {}).get('reconciled_changes', '—')})"
            print(f"| {r['shape']} | {size(r)} | {f((a or {}).get('apply', {}).get('p50_ms'))} | {f((u or {}).get('undo', {}).get('p50_ms'))} | {f((u or {}).get('redo', {}).get('p50_ms'))} | {f((s or {}).get('first_ms'))} | {f((s or {}).get('second_ms'))} | {replay} | {counts} |")

    print("\n### Memory, MB\n")
    print("| Shape | Size | text bytes | after open | end of run | peak resident |")
    print("|---|---|---|---|---|---|")
    for r in results:
        fx, o, s = phase(r, "fixture"), phase(r, "open"), phase(r, "summary")
        if fx:
            mb = fx["bytes"] / 1048576
            print(f"| {r['shape']} | {size(r)} | {mb:.1f} | {f((o or {}).get('footprint_after_open_mb'), 0)} | {f((s or {}).get('footprint_end_mb'), 0)} | {f((s or {}).get('peak_resident_mb'), 0)} |")


if __name__ == "__main__":
    main(sys.argv[1])
