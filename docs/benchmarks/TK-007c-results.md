# TK-007c: syntax highlighting through tree-sitter

Date: 2026-10-10. The bench and method are the same as in [TK-007a](TK-007a-results.md) and [TK-007b](TK-007b-results.md) (Apple M2, 8 GB, macOS 27.0, release, keystrokes via `insertText`, drawing into a bitmap via `cacheDisplay`). Raw data: [TK-007c-results.json](TK-007c-results.json) (the matrix) and [TK-007c-wide-lines.json](TK-007c-wide-lines.json) (long lines). Design — [ADR-014](../07_ARCHITECTURE_DECISIONS.md), section 007c.

The real chain is measured: session → `SyntaxCoordinator` → tree-sitter in the background → `SyntaxPresenter` → screen. In what follows, "colours" means exactly that, not the synthetic ranges from 007b.

## Short conclusions

1. **Highlighting works on ordinary Swift code and does not get in the way of typing.** p95 "input → draw" with colour is 9.8 ms at 10 MB (6.2 ms without colour); the costs on the main thread are small — parsing and querying run in the background, applying the result costs 0.1–0.4 ms (`main-thread refresh`). This is measured in a synthetic scenario with a bitmap, not as a delay to the screen.
2. **Colours lag behind a keystroke by 12 ms (up to 1 MB) and by 46 ms (10 MB):** that is how long it takes from a keystroke until the screen shows colours of this version. Typing does not wait: until the result arrives, colours move with the text, and the typed text is plain.
3. **First colours on opening:** 13 ms (41 KB), 170 ms (1 MB), 1.6 s (10 MB), all in the background; the window is shown at once without colour, and the colours appear by themselves.
4. **Memory:** +47 MB for a 1 MB file and +503 MB for 10 MB (≈ 50 bytes per byte of text: the parser's copy of the text and the tree). This set the threshold.
5. **Size threshold: 5 MB** (by linear extrapolation of the measured ≈ 250 MB and ≈ 0.8 s until the first colours). Larger files open without colour, and the window writes "syntax colours off: large file". 100 MB was not run: ≈ 5 GB of memory.
6. **Long lines: the cost of colour grows with the number of coloured runs.** Editing a 200-character line (about 36 runs) with colour costs 19 ms in this measurement against 5.5 ms without colour; a 1000-character line (≈ 180 runs) — 41 ms; a 4000-character one — 115 ms. Therefore a line longer than 1000 characters, or with more than 50 coloured runs, is drawn without colour. Both thresholds were chosen from these data, but the measurement is rough (see "What the limits mean").
7. **Correctness:** the results of incremental parsing equal the results of a fresh parse after each of 150 random edits (a mix of inserts, deletes, `\r\n`, emoji, comments, strings); the screen after edits equals, pixel for pixel, the screen coloured from scratch. Both tests fail without `tree.edit(...)` and without the range updates (checked by a mutation).

## Corrections after review

Two bugs found during the review were fixed; the full description and the reasons are in [ADR-014](../07_ARCHITECTURE_DECISIONS.md), section 007c. In brief: a crash when the document shrinks (a range beyond the end of the text); stale colours of a previously viewed area after an edit; and, found while reproducing, the disappearance of the last lines during a wide redraw, which is why the redraw is limited to the visible area. After the fixes the whole matrix was not run again: four scenarios (swift 1 MB, swift 10 MB, mixed 10 MB, giant 51 KB) were measured again, with typing p95 with colour of 9.7 / 9.8 / 10.5 / 82.3 ms, colour lag p50 of 11 / 45 / 44 / 83 ms, first colours of 158 ms / 1.6 s / 1.6 s; there are no significant differences from the table below. The table below remains the data of the first full run.

Later, during a manual check, one more problem was found: until `*/` is typed, an unclosed `/*` did not turn the code below it into a comment (the grammar recognises only a closed comment). It was fixed in the highlighter (see ADR-014); the cost is a search for `/*` over the copy of the text after each parse: the colour lag at 10 MB went from 45 to 51 ms, at 1 MB no change, typing no change.

## Matrix data

### Outcome

| Shape | Size | Lines | Finished | Wall, s | Last phase reached |
|---|---|---|---|---|---|
| swift | 41 KB | 1538 | yes | 4.6 | summary |
| swift | 1 MB | 38020 | yes | 5.4 | summary |
| swift | 10 MB | 380133 | yes | 9.9 | summary |
| swift | 100 MB | 3801089 | yes | 16.6 | summary |
| mixed | 10 MB | 355461 | yes | 9.8 | summary |
| short | 10 MB | 3495255 | yes | 4.4 | summary |
| giant | 51 KB | 1 | yes | 69.3 | summary |
| giant | 102 KB | 1 | yes | 120.9 | summary |
| giant | 256 KB | 1 | yes | 99.2 | summary |
| giant | 1 MB | 1 | timeout | 242.1 | typing |

### Opening (read → editor → session → first layout+draw), ms

| Shape | Size | read | make editor | session | line index | first layout+draw | total | footprint after open, MB |
|---|---|---|---|---|---|---|---|---|
| swift | 41 KB | 0.2 | 13.4 | 0.0 | 0.1 | 23.6 | 37.3 | 12 |
| swift | 1 MB | 1.6 | 9.8 | 0.0 | 1.2 | 23.8 | 36.3 | 17 |
| swift | 10 MB | 15.3 | 36.3 | 0.0 | 11.4 | 27.3 | 90.3 | 72 |
| swift | 100 MB | 170.9 | 286.7 | 0.0 | 120.8 | 22.3 | 600.7 | 743 |
| mixed | 10 MB | 14.2 | 34.7 | 0.0 | 10.3 | 23.9 | 83.2 | 72 |
| short | 10 MB | 10.9 | 8.7 | 0.0 | 27.4 | 18.8 | 65.9 | 135 |
| giant | 51 KB | 0.2 | 21.4 | 0.0 | 0.0 | 83.0 | 104.7 | 40 |
| giant | 102 KB | 0.3 | 9.1 | 0.0 | 0.1 | 140.0 | 149.5 | 44 |
| giant | 256 KB | 0.6 | 9.1 | 0.0 | 0.2 | 320.2 | 330.0 | 87 |
| giant | 1 MB | 2.3 | 16.2 | 0.0 | 1.0 | 1566.0 | 1585.5 | 431 |

### Typing: input → commit → layout+draw, ms (60 keystrokes per place)

| Shape | Size | Where | n | p50 | p95 | p99 | max | commit p95 | layout+draw p95 | reconciled | caret in view |
|---|---|---|---|---|---|---|---|---|---|---|---|
| swift | 41 KB | start | 60 | 5.7 | 5.9 | 10.4 | 10.4 | 1.0 | 5.1 | 0 | True |
| swift | 41 KB | middle | 60 | 5.9 | 6.0 | 6.4 | 6.4 | 0.9 | 5.3 | 0 | True |
| swift | 41 KB | end | 60 | 5.4 | 5.5 | 5.6 | 5.6 | 0.4 | 5.1 | 0 | True |
| swift | 41 KB | middle, rendering attributes | 60 | 8.7 | 9.6 | 37.8 | 37.8 | 1.3 | 8.5 | 0 | True |
| swift | 41 KB | middle, storage attributes | 60 | 7.2 | 7.4 | 7.6 | 7.6 | 1.0 | 6.5 | 0 | True |
| swift | 1 MB | start | 60 | 5.8 | 6.2 | 10.6 | 10.6 | 1.0 | 5.2 | 0 | True |
| swift | 1 MB | middle | 60 | 6.0 | 6.7 | 7.4 | 7.4 | 1.0 | 5.8 | 0 | True |
| swift | 1 MB | end | 60 | 5.8 | 6.4 | 7.2 | 7.2 | 0.5 | 5.8 | 0 | True |
| swift | 1 MB | middle, rendering attributes | 60 | 8.8 | 13.2 | 36.8 | 36.8 | 2.2 | 11.0 | 0 | True |
| swift | 1 MB | middle, storage attributes | 60 | 7.5 | 7.9 | 8.1 | 8.1 | 1.1 | 6.8 | 0 | True |
| swift | 10 MB | start | 60 | 5.8 | 6.9 | 11.2 | 11.2 | 1.1 | 5.6 | 0 | True |
| swift | 10 MB | middle | 60 | 6.0 | 6.2 | 6.5 | 6.5 | 0.8 | 5.5 | 0 | True |
| swift | 10 MB | end | 60 | 5.6 | 5.7 | 5.8 | 5.8 | 0.4 | 5.3 | 0 | True |
| swift | 10 MB | middle, rendering attributes | 60 | 8.3 | 8.5 | 8.6 | 8.6 | 0.8 | 7.7 | 0 | True |
| swift | 10 MB | middle, storage attributes | 60 | 7.3 | 7.5 | 7.8 | 7.8 | 1.0 | 6.6 | 0 | True |
| swift | 100 MB | start | 60 | 5.9 | 6.2 | 12.4 | 12.4 | 1.1 | 5.2 | 0 | True |
| swift | 100 MB | middle | 60 | 6.1 | 6.3 | 6.6 | 6.6 | 0.8 | 5.5 | 0 | True |
| swift | 100 MB | end | 60 | 5.7 | 5.8 | 6.1 | 6.1 | 0.5 | 5.4 | 0 | True |
| swift | 100 MB | middle, rendering attributes | 60 | 8.5 | 8.6 | 8.8 | 8.8 | 0.9 | 7.9 | 0 | True |
| swift | 100 MB | middle, storage attributes | 60 | 7.5 | 7.8 | 7.9 | 7.9 | 1.0 | 6.8 | 0 | True |
| mixed | 10 MB | start | 60 | 6.0 | 9.9 | 41.0 | 41.0 | 1.3 | 6.2 | 0 | True |
| mixed | 10 MB | middle | 60 | 6.2 | 6.4 | 6.6 | 6.6 | 0.9 | 5.5 | 0 | True |
| mixed | 10 MB | end | 60 | 5.6 | 5.8 | 6.0 | 6.0 | 0.4 | 5.4 | 0 | True |
| mixed | 10 MB | middle, rendering attributes | 60 | 9.2 | 9.6 | 9.6 | 9.6 | 1.2 | 8.5 | 0 | True |
| mixed | 10 MB | middle, storage attributes | 60 | 7.5 | 8.0 | 8.1 | 8.1 | 1.1 | 6.9 | 0 | True |
| short | 10 MB | start | 60 | 6.3 | 16.2 | 19.5 | 19.5 | 2.3 | 13.3 | 0 | True |
| short | 10 MB | middle | 60 | 6.0 | 6.2 | 6.3 | 6.3 | 0.7 | 5.5 | 0 | True |
| short | 10 MB | end | 60 | 5.7 | 5.8 | 5.9 | 5.9 | 0.4 | 5.4 | 0 | True |
| short | 10 MB | middle, rendering attributes | 60 | 6.0 | 6.2 | 6.4 | 6.4 | 0.8 | 5.5 | 0 | True |
| short | 10 MB | middle, storage attributes | 60 | 6.3 | 6.4 | 6.8 | 6.8 | 0.9 | 5.5 | 0 | True |
| giant | 51 KB | start | 60 | 94.5 | 148.2 | 183.6 | 183.6 | 15.5 | 133.6 | 0 | True |
| giant | 51 KB | middle | 60 | 80.3 | 84.2 | 86.6 | 86.6 | 15.7 | 68.6 | 0 | True |
| giant | 51 KB | end | 60 | 78.1 | 78.8 | 79.0 | 79.0 | 15.8 | 63.1 | 0 | True |
| giant | 51 KB | middle, rendering attributes | 60 | 454.9 | 457.5 | 461.6 | 461.6 | 216.4 | 241.3 | 0 | True |
| giant | 51 KB | middle, storage attributes | 60 | 198.4 | 201.1 | 209.2 | 209.2 | 36.3 | 164.9 | 0 | True |
| giant | 102 KB | start | 60 | 178.1 | 302.7 | 852.7 | 852.7 | 29.0 | 274.7 | 60 | True |
| giant | 102 KB | middle | 60 | 155.8 | 165.9 | 175.9 | 175.9 | 28.7 | 138.0 | 60 | True |
| giant | 102 KB | end | 60 | 149.0 | 149.9 | 150.9 | 150.9 | 28.5 | 121.5 | 60 | True |
| giant | 102 KB | middle, rendering attributes | 44 | 907.1 | 911.9 | 918.5 | 918.5 | 433.9 | 479.1 | 44 | True |
| giant | 102 KB | middle, storage attributes | 60 | 396.5 | 410.0 | 462.6 | 462.6 | 77.2 | 334.6 | 60 | True |
| giant | 256 KB | start | 60 | 471.6 | 961.4 | 8771.1 | 8771.1 | 70.6 | 892.1 | 60 | True |
| giant | 256 KB | middle | 60 | 407.5 | 442.5 | 479.9 | 479.9 | 71.3 | 371.6 | 60 | True |
| giant | 256 KB | end | 60 | 382.0 | 407.0 | 488.9 | 488.9 | 76.8 | 324.4 | 60 | True |
| giant | 1 MB | start | 7 | 1582.8 | 30167.3 | 30167.3 | 30167.3 | 380.3 | 29854.5 | 7 | True |
| giant | 1 MB | middle | 25 | 1595.6 | 1803.6 | 1855.8 | 1855.8 | 358.6 | 1412.6 | 25 | True |

### Building blocks (median of 3), ms

Before TK-011 a keystroke paid for the first three columns and the diff; after it, only for planning against the storage. A snapshot copies the document and is paid on save, not per keystroke.

| Shape | Size | backend text copy | compare equal | planner prepare | text diff | snapshot |
|---|---|---|---|---|---|---|
| swift | 41 KB | 0.1 | 0.1 | 0.003 | — | 0.1 |
| swift | 1 MB | 2.8 | 2.8 | 0.002 | — | 2.7 |
| swift | 10 MB | 27.7 | 28.1 | 0.002 | — | 27.1 |
| swift | 100 MB | 291.0 | 280.2 | 0.003 | — | 271.7 |
| mixed | 10 MB | 27.4 | 28.0 | 0.002 | — | 26.8 |
| short | 10 MB | 30.6 | 28.2 | 0.003 | — | 30.7 |
| giant | 51 KB | 0.1 | 0.1 | 0.002 | — | 0.2 |
| giant | 102 KB | 0.3 | 0.3 | 0.002 | — | 0.3 |
| giant | 256 KB | 0.7 | 0.7 | 0.002 | — | 0.7 |
| giant | 1 MB | 3.1 | 2.9 | 0.003 | — | 3.0 |

### Scrolling (jump + layout+draw), ms

| Shape | Size | to end | to middle | to start | caret in view (end/middle/start) |
|---|---|---|---|---|---|
| swift | 41 KB | 9.2 | 10.1 | 6.6 | True/True/True |
| swift | 1 MB | 9.3 | 10.1 | 6.7 | True/True/True |
| swift | 10 MB | 10.5 | 8.6 | 6.6 | True/True/True |
| swift | 100 MB | 10.0 | 8.3 | 6.8 | True/True/True |
| mixed | 10 MB | 9.3 | 10.6 | 6.7 | True/True/True |
| short | 10 MB | 10.1 | 8.5 | 7.0 | True/True/True |
| giant | 51 KB | 49.9 | 48.4 | 25.0 | True/True/True |
| giant | 102 KB | 94.4 | 92.7 | 46.7 | True/True/True |
| giant | 256 KB | 237.7 | 238.5 | 116.0 | True/True/True |
| giant | 1 MB | 986.5 | 974.2 | 465.1 | True/True/True |

### Margin: line numbers for the rows in view (median of 5), ms

| Shape | Size | lines | start | middle | end | rows labelled (start/middle/end) | 1000 lookups | index = fresh scan, rebuilds |
|---|---|---|---|---|---|---|---|---|
| swift | 41 KB | 1538 | 0.057 | 0.070 | 0.074 | 40/41/40 | 0.33 | True, 0 |
| swift | 1 MB | 38020 | 0.057 | 0.066 | 0.058 | 40/41/40 | 0.36 | True, 0 |
| swift | 10 MB | 380133 | 0.066 | 0.064 | 0.063 | 40/41/40 | 0.59 | True, 0 |
| swift | 100 MB | 3801089 | 0.059 | 0.072 | 0.077 | 40/41/40 | 0.68 | True, 0 |
| mixed | 10 MB | 368156 | 0.056 | 0.074 | 0.061 | 40/41/40 | 0.38 | True, 0 |
| short | 10 MB | 3495255 | 0.057 | 0.076 | 0.069 | 40/41/40 | 1.10 | True, 0 |
| giant | 51 KB | 1 | 0.003 | 0.003 | 0.003 | 1/1/1 | 0.02 | True, 0 |
| giant | 102 KB | 1 | 0.003 | 0.003 | 0.003 | 1/1/1 | 0.02 | True, 0 |
| giant | 256 KB | 1 | 0.003 | 0.003 | 0.003 | 1/1/1 | 0.02 | True, 0 |
| giant | 1 MB | 1 | 0.003 | 0.003 | 0.003 | 1/1/1 | 0.03 | —, — |

### Colours: refreshing what is in view, ms (typing with each approach is in the typing table)

Rendering attributes: a validator colours each fragment as it is laid out, refreshed with an attribute-only notification over the visible range. Storage: the same spans written into the text storage.

| Shape | Size | rendering start | middle | end | fragments / spans per refresh | in validator | storage start | middle | end | untouched (rendering / storage) | whole doc |
|---|---|---|---|---|---|---|---|---|---|---|---|
| swift | 41 KB | 10.1 | 10.4 | 9.9 | 41 / 116 | 0.34 | 10.1 | 9.9 | 9.8 | True / True | 8.2 |
| swift | 1 MB | 10.1 | 10.5 | 9.8 | 41 / 116 | 0.35 | 10.8 | 11.4 | 10.7 | True / True | 8.3 |
| swift | 10 MB | 10.1 | 10.1 | 10.0 | 42 / 105 | 0.32 | 10.2 | 9.8 | 9.7 | True / True | — |
| swift | 100 MB | 10.1 | 10.1 | 10.0 | 42 / 105 | 0.32 | 10.6 | 10.2 | 10.1 | True / True | — |
| mixed | 10 MB | 10.8 | 11.0 | 10.5 | 41 / 116 | 0.36 | 10.8 | 10.5 | 10.4 | True / True | — |
| short | 10 MB | 7.2 | 7.5 | 7.1 | 42 / 2 | 0.07 | 7.2 | 7.4 | 7.1 | True / True | — |
| giant | 51 KB | 183.6 | 182.1 | 183.7 | 1 / 3748 | 8.63 | 160.7 | 160.4 | 159.8 | True / True | 77.8 |
| giant | 102 KB | 362.9 | 362.1 | 366.4 | 1 / 7492 | 17.63 | 323.0 | 335.8 | 335.1 | True / True | 157.3 |

### Syntax colours (tree-sitter in the background, TK-007c)

Typing is measured with colours on: the keystroke (input to draw), the wait until the highlighter's answer for that version was received ("result"; the first version of this report called it "lag" and described it as "on screen", which it was not: it ended before the frame was drawn), and the draw that shows them. See "Review, second round" at the end for the measure that includes the drawing, and for a burst of keystrokes. Footprint is what the highlighter's text copy and syntax tree take.

| Shape | Size | first colours | footprint, MB | keystroke p50 / p95 | commit p95 | result p50 / p95 (was called "lag") | redraw p50 | main-thread refresh p95 | resyncs | spans in window |
|---|---|---|---|---|---|---|---|---|---|---|
| swift | 41 KB | 13 ms | 0 | 9.2 / 10.1 | 1.7 | 11.5 / 12.5 | 5.2 | 0.2 | 0 | 1426 |
| swift | 1 MB | 170 ms | 47 | 9.7 / 15.5 | 2.4 | 11.9 / 22.3 | 5.3 | 0.1 | 0 | 2855 |
| swift | 10 MB | 1608 ms | 503 | 9.4 / 9.8 | 1.3 | 46.3 / 52.1 | 5.9 | 0.2 | 0 | 2862 |
| mixed | 10 MB | 1548 ms | 491 | 10.0 / 10.2 | 1.9 | 46.4 / 49.2 | 5.7 | 0.1 | 0 | 2787 |
| giant | 51 KB | 99 ms | — | 80.7 / 81.8 | 16.3 | 83.0 / 84.0 | 32.4 | — | 0 | 0 |
| giant | 102 KB | 188 ms | — | 155.4 / 159.5 | 29.6 | 158.0 / 162.2 | 61.6 | — | 0 | 0 |

### Programmatic edit, undo, redo, save, ms (p50 unless noted)

| Shape | Size | apply | undo | redo | save #1 | save #2 | changes rebuilt = view | changes (reconciled) |
|---|---|---|---|---|---|---|---|---|
| swift | 41 KB | 0.4 | 5.3 | 5.3 | 3.9 | 2.0 | True | 384 (0) |
| swift | 1 MB | 0.5 | 5.4 | 5.4 | 7.1 | 5.5 | True | 384 (0) |
| swift | 10 MB | 0.4 | 5.5 | 5.6 | 45.1 | 43.5 | True | 384 (0) |
| swift | 100 MB | 0.5 | 5.7 | 5.6 | 408.5 | 408.5 | True | 324 (0) |
| mixed | 10 MB | 0.4 | 5.6 | 5.5 | 44.3 | 43.6 | True | 384 (0) |
| short | 10 MB | 0.5 | 5.6 | 5.6 | 46.4 | 45.6 | True | 324 (0) |
| giant | 51 KB | 0.5 | 77.6 | 77.7 | 57.3 | 3.5 | True | 384 (0) |
| giant | 102 KB | 0.6 | 149.7 | 149.5 | 110.5 | 93.9 | True | 368 (356) |
| giant | 256 KB | 0.5 | 379.6 | 399.2 | 336.2 | 3.5 | True | 204 (192) |

### Memory, MB

| Shape | Size | text bytes | after open | end of run | peak resident |
|---|---|---|---|---|---|
| swift | 41 KB | 0.0 | 12 | 38 | 126 |
| swift | 1 MB | 1.0 | 17 | 45 | 175 |
| swift | 10 MB | 10.0 | 72 | 351 | 713 |
| swift | 100 MB | 100.0 | 743 | 1207 | 1175 |
| mixed | 10 MB | 10.0 | 72 | 336 | 701 |
| short | 10 MB | 10.0 | 135 | 244 | 315 |
| giant | 51 KB | 0.1 | 40 | 128 | 414 |
| giant | 102 KB | 0.1 | 44 | 302 | 686 |
| giant | 256 KB | 0.3 | 87 | 715 | 1228 |
| giant | 1 MB | 1.0 | 431 | — | — |

Notes on the table: `footprint` on the giant lines is negative and not meaningful (TextKit frees memory between phases); `spans in window` is zero because the generated giant line (words mixed together) is not Swift. The outlier at 1 MB (typing p95 15.5 ms, maximum redraw 70 ms) did not repeat at the other sizes and is considered noise; one run per scenario.

## Long lines: where colour stops paying off

A 0.3 MB file made of lines `let valuesN = [1, 2, 3, ...]` of a given length (numbers are coloured, commas are not; about 0.18 coloured runs per character), colours without any policy limit. "Typing" is a keystroke in the middle of the file plus the drawing of the whole window; "commit" is the part of the keystroke before drawing (the layout of the edited line).

| Characters in line | Typing p50 without colour, ms | Typing p50 with colour, ms | of which commit, ms | Colour lag p50, ms |
|---|---|---|---|---|
| 100 | 6.3 | 21.6 | 2.0 | 24 |
| 200 | 5.5 | 19.2 / 19.0 (two runs) | 3.1 / 3.0 | 22 / 21 |
| 300 | 5.5 | 24.9 | 3.9 | 27 |
| 500 | 5.4 | 31.5 | 7.0 | 34 |
| 1000 | 5.6 | 40.8 | 12.0 | 44 |
| 2000 | 6.1 | 70.4 | 23.8 | 74 |
| 4000 | 6.4 | 114.9 | 65.6 | 120 |

What follows from this and what does not:

- "Typing with colour" includes drawing **all** coloured runs on the screen: the bench redraws the whole view via `cacheDisplay`, while in the application only the changed fragments are redrawn. Therefore the figures in the "Typing with colour" column are an upper estimate, and they grow with the number of coloured runs on the screen (here 20–40 lines of 30–180 runs each), not only with the length of a single line.
- The commit column shows the cost of editing one line: about 3 ms at ≈ 36 runs and about 12 ms at ≈ 180. A 16 ms budget per keystroke on a base of 6 ms leaves ≈ 10 ms, i.e. lines up to ≈ 100–150 runs by this column, and up to ≈ 50 by the estimate of the scrolling cost (≈ 0.02 ms per run in a new line). The smaller one was adopted: **50 runs**, and **1000 characters**.
- Therefore both thresholds (`SyntaxPolicy.maximumSpansPerFragment`, `maximumFragmentLength`) are preliminary; a measurement on real keystrokes and scrolling in a live window is needed.

## What is checked by automated tests

| Property | Test |
|---|---|
| A window that has received the result shows colours; without an answer there are no colours | `aDocumentIsColouredOnceTheHighlighterHasAnswered` |
| The document, revisions and undo are not affected by colour | `colouringTouchesNeitherTheDocumentNorItsUndoHistory` |
| After edits (an open line, an open and a closed comment) the screen equals a freshly coloured copy; the parser did not lose edits | `afterEditsTheScreenEqualsAFreshlyColouredCopy` |
| A line longer than the threshold and a line with too many runs stay without colour, and only because of the policy | `aLineLongerThanThePolicyIsLeftPlain`, `aLineWithTooManyColouredRunsIsLeftPlain` |
| Incremental parsing after each edit equals a fresh parse; a batch of edits in one `ChangeSet` | `incrementalColoursEqualThoseOfAFreshParseAfterEveryEdit`, `severalEditsInOneChangeSetAreAppliedLikeTheStorageDoes` |
| Stale requests and loss of synchronisation give no answer; an answer comes only after a reset | `aRequestForAnotherVersionGetsNoAnswer`, `anEditThatDoesNotFitSilencesTheHighlighterUntilItIsReset` |
| The colour state follows edits like the text; a result replaces only its own window; it reports where colours changed | `HighlightStateTests` (random sequences against a model) |
| The coordinator: order of messages, discarding of stale results, resynchronisation, holding changes during composition | `SyntaxCoordinatorTests` |
| The text in chunks equals an ordinary array through random edits | `ChunkedTextTests` |
| Stale colours of a rebuilt fragment do not stay on the screen if the validator stopped colouring | `aValidatorMustClearItsFragmentBecauseOldColoursStayOtherwise` |
| A document shrunk below what was on the screen: windows and requests stay inside the text | `aDocumentThatShrinksBelowTheVisibleTextStillGetsAWindowInsideIt`, `aDocumentEmptiedCompletelyIsHandled`, `aWindowBeyondTheEndOfTheTextIsAnsweredWithNothingInsteadOfCrashing`, `aShrunkenDocumentIsAnsweredForAWindowThatUsedToFit`, `aDocumentCutDownWhileScrolledFarDownKeepsWorking` |
| The known window is only what the latest answer describes; an old version's window is not known for the new version | `theKnownWindowIsOnlyWhatTheLatestAnswerDescribes`, `anAreaSeenBeforeAnEditIsAskedForAgainWhenItComesBackIntoView`, `anOldWindowIsNotKnownColoursOfTheNewVersionUntilItsAnswerComes` |
| An area laid out before an edit is recoloured after it when scrolled back to, and the lines stay in place | `textSeenBeforeAnEditIsRecolouredWhenScrolledBackToAfterIt` (the screen equals a freshly coloured one; checked by mutations: without limiting the redraw to the visible area and without a reaction to scrolling, the test fails) |
| Deferred changes follow edits and are delivered when their text is in the visible area; the visible area follows edits | `stretchesAwaitingARedrawFollowEditsAndAreTakenByPlace`, `aChangeOutOfViewWaitsUntilItsTextIsScrolledTo`, `whatIsInViewMovesWithTheText` |
| The order of messages to the highlighter (the handler goes through the same queue) | `aRequestSentRightAfterConnectingIsNeverLost` (a load test; did not fail on the old version) |

## Not checked

- IME composition with highlighting enabled (during composition updates are postponed; not checked by hand).
- Real keystrokes, scrolling and redrawing in a live window (a snapshot of the application window was checked: colours, numbering, dark theme).
- Pasting a very large fragment (10 MB as one `ChangeSet` is applied as one edit to the copy of the text and the tree; the time was not measured).
- The light theme for the colours themselves: the palette is set, the screenshot is of the dark theme only.
- Other languages: only the Swift grammar is connected; the extension `.swift` in the window path.
- Building the dependencies on other Xcode versions; checked on Swift 6.4 / macOS 27.0.

## Limitations

The same as in TK-007a/b: one run per scenario, one machine, synthetic keystrokes, a bitmap. The tree and the copy of the text are separate for each window.

## Review, second round (2026-10-10): what was measured, and a burst of keystrokes

Data: [TK-007c-review-2.json](TK-007c-review-2.json). The same machine and bench; only the highlighting phases were run (`PHASES=syntax`).

**1. "Colour lag" was the time to receive the result, not the time to the picture.** The old column ended when the coordinator accepted the answer for that version, before drawing; besides, the answer could describe not the part of the text that was on the screen. Now two things are measured: *result* (the former number) and *picture* — until the answer for this version covers the visible text and a frame has been drawn after it.

| Size | result p50 / p95 | picture p50 / p95 |
|---|---|---|
| 1 MB | 11.2 / 12.0 ms | 17.7 / 18.1 ms |
| 10 MB | 51.7 / 53.0 ms | 57.6 / 59.2 ms |

The picture lags the result by 6 ms (drawing a frame), at both sizes. The earlier figures in the tables above are *result*; for the picture, ≈ 6 ms must be added to them.

**2. A series of keystrokes without waiting for the highlighting between them.** The old bench waited for the background after each character and did not show the queue. Sixty keystrokes in a row, one colour request for each:

| Size | build | typing p50 / p95 | colours ready after the last key | answers / skipped | parse | search for unclosed `/*` | choosing runs |
|---|---|---|---|---|---|---|---|
| 1 MB | before | 9.0 / 9.2 ms | 3 ms | 60 / 0 | 131 ms | 31 ms | 281 ms |
| 1 MB | after | 9.0 / 9.2 ms | 3 ms | 60 / 0 | 129 ms | 32 ms | 282 ms |
| 10 MB | **before** | 8.9 / 9.2 ms | **2240 ms** | 60 / 0 | 2230 ms | 311 ms | 282 ms |
| 10 MB | **after** | 9.0 / 9.4 ms | **57 ms** | 13 / 47 | 523 ms | 69 ms | 61 ms |

At 10 MB the queue was building up: each keystroke posted a request, the background parsed the text for each, and the editor discarded the answers for old versions. The colours were ready 2.2 s after the last keystroke. Fixed: a request for which a newer one is already in the queue is skipped (its answer would be discarded anyway). Now 47 of 60 are skipped, and the colours are ready in 57 ms. Typing on the main thread did not change (it never depended on the background). At 1 MB the background keeps up with typing, there are no skips, and the result is as before.

**3. The search for an unclosed `/*` is a separate O(n) background cost.** It reads the whole text of the copy after each parse: 5.2 ms per request at 10 MB (311 ms out of 2.8 s of total background work), 0.5 ms at 1 MB. This is ≈ 12% of the parse, not the main item, and after the queue fix it is paid 13 times instead of 60. But the cost grows with the size of the file, not with the edit; it has not been reduced yet (searching only the changed part), because the 5 MB highlighting limit caps it at ≈ 2.5 ms.

**What was not checked in this round:** the matrix was not re-run in full; 100 MB and wide lines were not measured in this mode; the values come from one run.
