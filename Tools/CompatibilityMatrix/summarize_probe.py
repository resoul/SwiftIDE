#!/usr/bin/env python3
"""Prints probe results as one compact table (case, phase, question, ok, seconds)."""
import json, sys
for path in sys.argv[1:]:
    r = json.load(open(path))
    head = f"{r['case']} / {r['phase']}  (initialize {r.get('initialize_seconds')} s)"
    if 'initialize_error' in r:
        print(head, 'INITIALIZE ERROR', r['initialize_error']); continue
    print(head)
    for key in ('questions', 'after_restart'):
        for name, q in r.get(key, {}).items():
            print(f"  {'restart ' if key == 'after_restart' else ''}{'OK ' if q['ok'] else 'NO '} {q['seconds']:>7} s  {name}")
