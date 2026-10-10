# TK-011: re-measurement after switching to O(edit) cost

> **Correction (2026-10-09).** The "middle" and "end" measurements in this report measured the top of the document: the text view could not grow above its initial height, and the window did not scroll. The commit cost and the O(edit) conclusion remain valid; the layout+draw figures for middle and end are wrong. The fix and the recalculation: [TK-007a](TK-007a-results.md).

Date: 2026-10-09. Same bench, tool and method as in [TK-008](TK-008-results.md) (Apple M2, 8 GB, macOS 27.0, release, corrected method with an autorelease pool). The change — [ADR-012](../07_ARCHITECTURE_DECISIONS.md): the session no longer keeps a copy of the text; edits are described by `editedRange`/`changeInLength`, and the planner reads only the replaced fragment. Raw data: [TK-011-results.json](TK-011-results.json).

## Short conclusions

1. **The goal is reached.** Typing no longer depends on file size: p95 "input → draw" is 4.2–5.3 ms at any size from 41 KB to 100 MB with lines of ordinary length. In the **measured synthetic scenario** (keystrokes via `insertText`, drawing into a bitmap via `cacheDisplay`) this fits the 16 ms budget with a large margin; the real delay to the screen (WindowServer, compositor, display, a real `keyDown`) was **not measured**, so this measurement does not prove "the budget holds in the app". The whole cost is layout and drawing of the visible area (≈ 4 ms) plus the commit ≈ 1 ms.
2. **Programmatic edit and undo also stopped depending on size:** 0.3–0.4 ms and 3.9 ms at 100 MB instead of 3.5 s and 2.7 s.
3. **Memory and opening improved as a side effect:** peak at 100 MB 1.49 GB → 0.78 GB, opening 780 → 454 ms (session initialisation with a text copy 314 ms → 0.01 ms).
4. **The price is saving.** The text copy is now made at the moment of the snapshot, not on every keystroke: Save became slower (10 MB: 22 → 45 ms; 100 MB: 170 → 424 ms), of which ≈ 270 ms at 100 MB is the main thread blocked for the copy. For a rare event this is the right trade-off, but on very large files it is noticeable; it must be removed separately (copying in parts, or reading the backend from a background thread) if it becomes a problem. **Done** ([ADR-018](../07_ARCHITECTURE_DECISIONS.md)): the pause at 100 MB 306 ms → 0.1–0.3 ms (the first capture up to 27 ms).
5. **The giant line did not change**, as expected: it is layout inside TextKit (1.3 ms per KB of the line). It is solved by a separate task, not by this ADR.

## Before and after (worst input p95 of the three places — start, middle, end)

| File | Input p95 | Programmatic edit p50 | Undo p50 | Opening | Save #1 | Peak memory, MB |
|---|---|---|---|---|---|---|
| swift 41 KB | 5.8 ms → **4.8 ms** | 1.6 ms → **0.3 ms** | 5.0 ms → **3.9 ms** | 43 ms → 95 ms | 9.8 ms → 3.8 ms | 90 → 90 |
| swift 1 MB | 25 ms → **5.3 ms** | 36 ms → **0.3 ms** | 31 ms → **4.0 ms** | 40 ms → 31 ms | 6.9 ms → 7.4 ms | 108 → 101 |
| swift 10 MB | 190 ms → **5.1 ms** | 352 ms → **0.3 ms** | 273 ms → **3.9 ms** | 101 ms → 69 ms | 22 ms → 46 ms | 206 → 182 |
| swift 100 MB | 1.9 s → **4.7 ms** | 3.5 s → **0.3 ms** | 2.7 s → **3.9 ms** | 780 ms → 506 ms | 171 ms → 405 ms | 1493 → 1089 |
| mixed 10 MB | 189 ms → **5.1 ms** | 351 ms → **0.4 ms** | 273 ms → **3.9 ms** | 99 ms → 73 ms | 21 ms → 43 ms | 216 → 182 |
| short 10 MB | 144 ms → **5.1 ms** | 325 ms → **0.4 ms** | 180 ms → **4.0 ms** | 67 ms → 40 ms | 20 ms → 48 ms | 187 → 176 |

All values: TK-008 → **TK-011**; bold is what ADR-012 changed.

## Correctness checks

- **Independent proof.** Each scenario records all `DocumentChangeSet`s published by the session (typing, programmatic edits, undo/redo) and at the end applies them in order to the file's original text. The resulting string is compared with the view's text. It is built only from the published edits, not from reading the same backend, so a match means that subscribers applying the changes will restore the same document. Result: **matched in all 9 completed scenarios** (204 change sets each; 200 in the giant 256 KB line, where some input phases were cut short by time).
- Accuracy of edit descriptions. On lines of ordinary length `reconciled` = 0 for all keystrokes: the edit is confirmed by the paragraph contents and described exactly. On a giant line over 64 KB (the paragraph context that the bridge is ready to compare is limited), the edit cannot be confirmed, and every keystroke is published as a **region** — the whole paragraph (`reconciled` = 60 of 60 on the 102 and 256 KB lines; in TK-008 it was 0). The result remains correct (see the reproduction above), but the subscriber gets a replacement of ~100–250 KB per keystroke. For lines of this length this is secondary to TextKit's layout (150–470 ms per keystroke), but it is a cost to account for in the long-line mode.
- At 100 MB all 60 keystrokes are now typed in each place (previously 22–31 because of the phase time limit); the whole scenario takes 14 s instead of 216 s.
- Automated tests (93 + 24) pin the invariant: a test on a real `NSTextView` checks that typing, pasting, undo, redo, programmatic edits and composition do not copy the text even once (`textMaterializations == 0`), and that `snapshot()` copies exactly once; the test fails if a copy is put back on the edit path (checked by a mutation).

## New limits (for the current build)

| Parameter | Value | Basis |
|---|---|---|
| Editing (16 ms budget) | up to 100 MB of ordinary code | measured in the synthetic bitmap scenario: p95 ≈ 4–6 ms; delay to the screen not measured |
| Opening | 100 MB in 0.45 s, memory ≈ 5.4× the file after opening, peak 0.78 GB | measured |
| Saving | grows linearly: ≈ 0.45 s per 100 MB, of which the copy ≈ 0.27 s on the main thread | measured |
| One line | unchanged: the budget is broken above ≈ 10 KB, 1 MB is unusable | TK-008, TextKit |

Consequences:
- The 100 MB opening limit can stay as it is. A higher one was not tested (on 8 GB of memory it would hit ≈ 5.4× the file size).
- Problem No. 1 next is long lines: detection on opening, a warning, then a long-line mode.
- Blocking of the main thread on Save for large files is a candidate for a separate task.

## Limitations

The same as in TK-008: one run per scenario, one machine, synthetic keystrokes, drawing into a bitmap (a lower-bound estimate of the delay to the screen). Spread between runs: input p95 ±5%; peak memory between runs fluctuates noticeably. The 1 MB giant line hit the 242 s timeout again (the undo and save phases were not run); the 10 MB and 100 MB line scenarios were deliberately not run.

## Full tables

### Outcome

| Shape | Size | Lines | Finished | Wall, s | Last phase reached |
|---|---|---|---|---|---|
| swift | 41 KB | 1538 | yes | 1.5 | summary |
| swift | 1 MB | 38020 | yes | 1.5 | summary |
| swift | 10 MB | 380133 | yes | 2.7 | summary |
| swift | 100 MB | 3801089 | yes | 14.4 | summary |
| mixed | 10 MB | 355461 | yes | 2.7 | summary |
| short | 10 MB | 3495255 | yes | 2.5 | summary |
| giant | 51 KB | 1 | yes | 17.9 | summary |
| giant | 102 KB | 1 | yes | 35 | summary |
| giant | 256 KB | 1 | yes | 99 | summary |
| giant | 1 MB | 1 | timeout | 242.2 | typing |

### Opening (read → editor → session → first layout+draw), ms

| Shape | Size | read | make editor | session | first layout+draw | total | footprint after open, MB |
|---|---|---|---|---|---|---|---|
| swift | 41 KB | 0.2 | 19.9 | 0.0 | 74.8 | 94.8 | 11 |
| swift | 1 MB | 1.6 | 10.0 | 0.0 | 19.3 | 31.0 | 17 |
| swift | 10 MB | 14.3 | 34.5 | 0.0 | 20.2 | 69.0 | 65 |
| swift | 100 MB | 196.7 | 288.0 | 0.0 | 21.5 | 506.2 | 657 |
| mixed | 10 MB | 14.1 | 34.0 | 0.0 | 24.7 | 72.8 | 65 |
| short | 10 MB | 10.7 | 8.5 | 0.0 | 20.7 | 39.9 | 50 |
| giant | 51 KB | 0.2 | 19.1 | 0.0 | 85.4 | 104.7 | 40 |
| giant | 102 KB | 0.3 | 6.8 | 0.0 | 142.1 | 149.2 | 44 |
| giant | 256 KB | 0.5 | 7.5 | 0.0 | 323.3 | 331.3 | 87 |
| giant | 1 MB | 1.9 | 12.7 | 0.0 | 1271.1 | 1285.7 | 288 |

### Typing: input → commit → layout+draw, ms (60 keystrokes per place)

| Shape | Size | Where | n | p50 | p95 | p99 | max | commit p95 | layout+draw p95 | reconciled |
|---|---|---|---|---|---|---|---|---|---|---|
| swift | 41 KB | start | 60 | 4.4 | 4.8 | 12.6 | 12.6 | 0.9 | 3.9 | 0 |
| swift | 41 KB | middle | 60 | 4.4 | 4.6 | 6.3 | 6.3 | 1.0 | 3.6 | 0 |
| swift | 41 KB | end | 60 | 4.1 | 4.4 | 4.8 | 4.8 | 0.7 | 3.8 | 0 |
| swift | 1 MB | start | 60 | 4.6 | 5.3 | 10.8 | 10.8 | 1.0 | 4.3 | 0 |
| swift | 1 MB | middle | 60 | 4.5 | 4.6 | 4.8 | 4.8 | 1.1 | 3.6 | 0 |
| swift | 1 MB | end | 60 | 4.2 | 4.6 | 4.8 | 4.8 | 0.8 | 3.9 | 0 |
| swift | 10 MB | start | 60 | 4.6 | 5.1 | 11.2 | 11.2 | 1.0 | 4.1 | 0 |
| swift | 10 MB | middle | 60 | 4.4 | 4.5 | 4.6 | 4.6 | 1.0 | 3.6 | 0 |
| swift | 10 MB | end | 60 | 4.1 | 4.3 | 4.3 | 4.3 | 0.7 | 3.6 | 0 |
| swift | 100 MB | start | 60 | 4.5 | 4.7 | 11.9 | 11.9 | 0.9 | 3.9 | 0 |
| swift | 100 MB | middle | 60 | 4.4 | 4.5 | 4.5 | 4.5 | 0.9 | 3.7 | 0 |
| swift | 100 MB | end | 60 | 4.1 | 4.3 | 4.4 | 4.4 | 0.7 | 3.6 | 0 |
| mixed | 10 MB | start | 60 | 4.7 | 5.1 | 10.9 | 10.9 | 1.0 | 4.2 | 0 |
| mixed | 10 MB | middle | 60 | 4.5 | 4.6 | 5.0 | 5.0 | 1.1 | 3.6 | 0 |
| mixed | 10 MB | end | 60 | 4.2 | 4.3 | 4.4 | 4.4 | 0.7 | 3.7 | 0 |
| short | 10 MB | start | 60 | 4.7 | 5.1 | 11.1 | 11.1 | 1.0 | 4.2 | 0 |
| short | 10 MB | middle | 60 | 4.5 | 4.5 | 4.6 | 4.6 | 0.9 | 3.7 | 0 |
| short | 10 MB | end | 60 | 4.1 | 4.2 | 4.3 | 4.3 | 0.6 | 3.6 | 0 |
| giant | 51 KB | start | 60 | 95.6 | 134.4 | 202.7 | 202.7 | 15.5 | 119.3 | 0 |
| giant | 51 KB | middle | 60 | 80.0 | 83.5 | 86.2 | 86.2 | 16.5 | 68.3 | 0 |
| giant | 51 KB | end | 60 | 77.4 | 78.5 | 80.3 | 80.3 | 16.2 | 62.4 | 0 |
| giant | 102 KB | start | 60 | 180.9 | 310.0 | 913.9 | 913.9 | 28.4 | 282.6 | 60 |
| giant | 102 KB | middle | 60 | 156.3 | 165.3 | 185.3 | 185.3 | 28.4 | 136.7 | 60 |
| giant | 102 KB | end | 60 | 148.6 | 151.0 | 161.6 | 161.6 | 29.6 | 121.5 | 60 |
| giant | 256 KB | start | 56 | 488.7 | 1165.5 | 9007.3 | 9007.3 | 70.9 | 1097.9 | 56 |
| giant | 256 KB | middle | 60 | 418.4 | 465.8 | 501.4 | 501.4 | 73.7 | 394.9 | 60 |
| giant | 256 KB | end | 60 | 379.2 | 396.3 | 482.6 | 482.6 | 73.8 | 322.6 | 60 |
| giant | 1 MB | start | 5 | 2084.7 | 33836.6 | 33836.6 | 33836.6 | 297.4 | 33548.2 | 5 |
| giant | 1 MB | middle | 26 | 1551.1 | 1624.1 | 1627.8 | 1627.8 | 290.4 | 1337.6 | 26 |

### Building blocks (median of 3), ms

Before TK-011 a keystroke paid for the first three columns and the diff; after it, only for planning against the storage. A snapshot copies the document and is paid on save, not per keystroke.

| Shape | Size | backend text copy | compare equal | planner prepare | text diff | snapshot |
|---|---|---|---|---|---|---|
| swift | 41 KB | 0.1 | 0.1 | 0.002 | — | 0.1 |
| swift | 1 MB | 2.7 | 2.8 | 0.002 | — | 2.7 |
| swift | 10 MB | 27.1 | 28.0 | 0.002 | — | 26.4 |
| swift | 100 MB | 288.2 | 280.9 | 0.003 | — | 268.8 |
| mixed | 10 MB | 27.0 | 28.2 | 0.002 | — | 26.7 |
| short | 10 MB | 30.0 | 28.2 | 0.002 | — | 29.7 |
| giant | 51 KB | 0.2 | 0.1 | 0.002 | — | 0.1 |
| giant | 102 KB | 0.3 | 0.3 | 0.002 | — | 0.3 |
| giant | 256 KB | 0.7 | 0.7 | 0.002 | — | 0.7 |
| giant | 1 MB | 2.9 | 2.8 | 0.002 | — | 2.8 |

### Scrolling (jump + layout+draw), ms

| Shape | Size | to end | to middle | to start |
|---|---|---|---|---|
| swift | 41 KB | 4.1 | 4.4 | 3.5 |
| swift | 1 MB | 4.3 | 4.5 | 3.6 |
| swift | 10 MB | 4.4 | 4.3 | 3.3 |
| swift | 100 MB | 4.7 | 4.3 | 3.6 |
| mixed | 10 MB | 4.3 | 4.6 | 3.4 |
| short | 10 MB | 4.2 | 4.3 | 3.4 |
| giant | 51 KB | 23.9 | 24.0 | 23.7 |
| giant | 102 KB | 45.0 | 45.4 | 44.7 |
| giant | 256 KB | 109.7 | 111.3 | 112.6 |
| giant | 1 MB | 448.9 | 459.3 | 462.1 |

### Programmatic edit, undo, redo, save, ms (p50 unless noted)

| Shape | Size | apply | undo | redo | save #1 | save #2 | changes rebuilt = view | changes (reconciled) |
|---|---|---|---|---|---|---|---|---|
| swift | 41 KB | 0.3 | 3.9 | 3.9 | 3.8 | 3.5 | True | 204 (0) |
| swift | 1 MB | 0.3 | 4.0 | 3.9 | 7.4 | 5.5 | True | 204 (0) |
| swift | 10 MB | 0.3 | 3.9 | 3.9 | 45.8 | 42.5 | True | 204 (0) |
| swift | 100 MB | 0.3 | 3.9 | 3.8 | 405.5 | 401.1 | True | 204 (0) |
| mixed | 10 MB | 0.4 | 3.9 | 3.9 | 43.4 | 42.3 | True | 204 (0) |
| short | 10 MB | 0.4 | 4.0 | 4.0 | 47.8 | 45.1 | True | 204 (0) |
| giant | 51 KB | 0.4 | 77.0 | 76.5 | 56.6 | 2.2 | True | 204 (0) |
| giant | 102 KB | 0.5 | 149.9 | 151.0 | 109.8 | 3.5 | True | 204 (192) |
| giant | 256 KB | 0.5 | 382.8 | 381.3 | 285.6 | 3.4 | True | 200 (188) |

### Memory, MB

| Shape | Size | text bytes | after open | end of run | peak resident |
|---|---|---|---|---|---|
| swift | 41 KB | 0.0 | 11 | 17 | 90 |
| swift | 1 MB | 1.0 | 17 | 30 | 101 |
| swift | 10 MB | 10.0 | 65 | 111 | 182 |
| swift | 100 MB | 100.0 | 657 | 1059 | 1089 |
| mixed | 10 MB | 10.0 | 65 | 111 | 182 |
| short | 10 MB | 10.0 | 50 | 106 | 176 |
| giant | 51 KB | 0.1 | 40 | 78 | 198 |
| giant | 102 KB | 0.1 | 44 | 189 | 369 |
| giant | 256 KB | 0.3 | 87 | 843 | 1317 |
| giant | 1 MB | 1.0 | 288 | — | — |
