# TK-007a: line index and gutter, re-measurement with corrected scrolling

Date: 2026-10-09. The bench and method are the same as in [TK-008](TK-008-results.md) and [TK-011](TK-011-results.md) (Apple M2, 8 GB, macOS 27.0, release). Changes: the line index (`LineIndex`, [ADR-014](../07_ARCHITECTURE_DECISIONS.md)), a line-number gutter in the window, and **a fix to the height of `NSTextView`** (see below). Raw data: [TK-007a-results.json](TK-007a-results.json).

## Correction to TK-008 and TK-011

While preparing the gutter it turned out that `NSTextView` could not grow above its initial height: `maxSize` defaults to the initial frame (640 pt), and `isVerticallyResizable` does not override that. Consequences:

1. **In the application a long file did not scroll** beyond the first screen. Fixed in `TextKitEditorFactory` (`maxSize` without a limit), pinned by a test (`aLongFileCanBeScrolled`; checked by a mutation: without the fix the test fails).
2. **The "middle" and "end" measurements in TK-008 and TK-011 measured the top of the document.** The caret was placed in the middle, but the window stayed at offset 0, and the first lines were drawn into the bitmap. Scrolling ("jump to end/middle") also scrolled nothing. So the "layout+draw ≈ 4 ms" in those reports applies to the top of the file.
3. What remains valid: the cost of the **commit** and of the whole edit pipeline (`commit` ≈ 1 ms, programmatic edit 0.3–0.5 ms, undo 4–6 ms), O(edit) instead of O(file), the correctness of the reproduction, and the behaviour of the giant line. None of them depended on what was drawn.

Now every phase checks that the caret is actually in the visible area (`caret in view`), and it is `True` everywhere.

## Short conclusions

1. **Line index:** building it on opening takes 0.1 ms for 41 KB, 1.1 ms for 1 MB, 13 ms for 10 MB, **161 ms for 100 MB** (3.8 million lines); 30 ms for 10 MB of 3.5 million short lines. This is a single pass over the text, on the main thread; I am not splitting it into slices until it gets in the way (opening 100 MB overall is 0.73 s).
2. **The cost of an edit in the index is not visible in the measurement:** the `commit` p95 stayed at ≈ 1 ms (publishing a change already includes the index update). Correctness: after the whole series of edits, undo and redo the index equals a fresh scan (`index = fresh scan` in the table), and there were no rebuilds along the way (`rebuilds` = 0).
3. **The gutter is cheap:** preparing the numbers for the visible lines takes 0.06–0.08 ms at any size (40–41 lines in the window), 1000 queries "offset → line" take 0.3–2.7 ms.
4. **Input latency on ordinary lines with honest scrolling:** p95 "input → draw" is 5.7–7.8 ms for files from 41 KB to 100 MB. This is higher than the earlier 4–5 ms: the earlier figures were for the top of the file, and now the line-number strip is drawn too. In this build of the matrix two scenarios gave outliers: 10 MB (p95 18 and 24 ms) and 100 MB in the middle (12.6 ms). Three separate re-runs of 10 MB gave 5.8–6.8 ms everywhere, so the outlier is tied to machine noise during a long run, not to a property of the scenario. The matrix data is kept as it was.
5. **The 16 ms budget** holds in the measured synthetic scenario (keystrokes via `insertText`, drawing into a bitmap via `cacheDisplay`). The real delay to the screen with a real `keyDown` (WindowServer, compositor, display) was not measured.
6. **The giant line** is unchanged in substance: the cost is in TextKit layout; 1 MB hit the 242 s timeout again. On lines over 64 KB each keystroke is published as a region (the whole paragraph), as described in TK-011.

## The cost of the index

| File | Lines | Build | Memory beyond opening |
|---|---|---|---|
| swift 10 MB | 380 thousand | 13 ms | ≈ 9 MB |
| swift 100 MB | 3.8 million | 161 ms | ≈ 86 MB |
| short 10 MB | 3.5 million | 30 ms | ≈ 87 MB |

This is ≈ 23–25 bytes per line at build time: the builder first collects a flat array of lengths, then splits it into chunks, and both copies exist at the same time. It can be reduced to ≈ 8 bytes per line by building the chunks directly; I have not done that yet.

## Limitations

The same as in TK-008 and TK-011: one run per scenario, one machine, synthetic keystrokes, a bitmap (a lower-bound estimate of the delay to the screen). The scrollbar and dragging the thumb were not measured; the height of the document is estimated by TextKit itself. The look of the line-number strip in the live window was checked from a bitmap snapshot in light and dark themes, but not by hand in the application.

## Full tables

### Outcome

| Shape | Size | Lines | Finished | Wall, s | Last phase reached |
|---|---|---|---|---|---|
| swift | 41 KB | 1538 | yes | 1.9 | summary |
| swift | 1 MB | 38020 | yes | 1.9 | summary |
| swift | 10 MB | 380133 | yes | 3.9 | summary |
| swift | 100 MB | 3801089 | yes | 16.5 | summary |
| mixed | 10 MB | 355461 | yes | 3.3 | summary |
| short | 10 MB | 3495255 | yes | 3.3 | summary |
| giant | 51 KB | 1 | yes | 19 | summary |
| giant | 102 KB | 1 | yes | 36 | summary |
| giant | 256 KB | 1 | yes | 99.7 | summary |
| giant | 1 MB | 1 | timeout | 242.3 | typing |

### Opening (read → editor → session → first layout+draw), ms

| Shape | Size | read | make editor | session | line index | first layout+draw | total | footprint after open, MB |
|---|---|---|---|---|---|---|---|---|
| swift | 41 KB | 0.4 | 31.0 | 0.0 | 0.1 | 22.4 | 53.8 | 12 |
| swift | 1 MB | 1.6 | 10.7 | 0.0 | 1.1 | 21.8 | 35.2 | 17 |
| swift | 10 MB | 16.8 | 37.1 | 0.0 | 12.8 | 41.1 | 107.8 | 72 |
| swift | 100 MB | 199.3 | 325.8 | 0.0 | 161.0 | 43.4 | 729.6 | 643 |
| mixed | 10 MB | 15.7 | 39.5 | 0.0 | 12.2 | 29.4 | 96.9 | 72 |
| short | 10 MB | 11.0 | 9.3 | 0.0 | 30.1 | 22.5 | 73.0 | 135 |
| giant | 51 KB | 0.2 | 32.8 | 0.0 | 0.1 | 86.2 | 119.2 | 40 |
| giant | 102 KB | 0.3 | 7.4 | 0.0 | 0.1 | 146.9 | 154.7 | 44 |
| giant | 256 KB | 0.6 | 9.4 | 0.0 | 0.2 | 328.4 | 338.6 | 87 |
| giant | 1 MB | 2.2 | 11.9 | 0.0 | 0.6 | 1259.8 | 1274.5 | 432 |

### Typing: input → commit → layout+draw, ms (60 keystrokes per place)

| Shape | Size | Where | n | p50 | p95 | p99 | max | commit p95 | layout+draw p95 | reconciled | caret in view |
|---|---|---|---|---|---|---|---|---|---|---|---|
| swift | 41 KB | start | 60 | 5.9 | 7.7 | 10.6 | 10.6 | 1.1 | 5.8 | 0 | True |
| swift | 41 KB | middle | 60 | 5.9 | 6.5 | 8.0 | 8.0 | 1.0 | 5.6 | 0 | True |
| swift | 41 KB | end | 60 | 5.5 | 5.7 | 5.8 | 5.8 | 0.5 | 5.3 | 0 | True |
| swift | 1 MB | start | 60 | 5.8 | 6.2 | 11.9 | 11.9 | 1.0 | 5.4 | 0 | True |
| swift | 1 MB | middle | 60 | 6.0 | 6.9 | 8.5 | 8.5 | 1.1 | 6.0 | 0 | True |
| swift | 1 MB | end | 60 | 5.7 | 7.0 | 9.2 | 9.2 | 0.5 | 6.4 | 0 | True |
| swift | 10 MB | start | 60 | 7.9 | 18.2 | 26.0 | 26.0 | 2.8 | 13.2 | 0 | True |
| swift | 10 MB | middle | 60 | 10.4 | 23.7 | 38.7 | 38.7 | 3.1 | 21.4 | 0 | True |
| swift | 10 MB | end | 60 | 5.9 | 8.0 | 10.0 | 10.0 | 0.6 | 7.4 | 0 | True |
| swift | 100 MB | start | 60 | 6.6 | 7.8 | 26.2 | 26.2 | 1.6 | 6.3 | 0 | True |
| swift | 100 MB | middle | 60 | 6.8 | 12.6 | 14.9 | 14.9 | 1.9 | 11.3 | 0 | True |
| swift | 100 MB | end | 60 | 6.0 | 6.5 | 8.0 | 8.0 | 0.6 | 6.0 | 0 | True |
| mixed | 10 MB | start | 60 | 6.1 | 6.9 | 11.8 | 11.8 | 1.0 | 5.9 | 0 | True |
| mixed | 10 MB | middle | 60 | 6.4 | 6.8 | 7.9 | 7.9 | 1.0 | 5.9 | 0 | True |
| mixed | 10 MB | end | 60 | 6.2 | 10.0 | 138.2 | 138.2 | 1.1 | 9.0 | 0 | True |
| short | 10 MB | start | 60 | 6.1 | 7.4 | 11.3 | 11.3 | 1.1 | 5.9 | 0 | True |
| short | 10 MB | middle | 60 | 6.2 | 6.6 | 8.3 | 8.3 | 0.8 | 5.8 | 0 | True |
| short | 10 MB | end | 60 | 5.9 | 6.2 | 6.2 | 6.2 | 0.5 | 5.7 | 0 | True |
| giant | 51 KB | start | 60 | 102.5 | 164.1 | 213.8 | 213.8 | 20.2 | 143.9 | 0 | True |
| giant | 51 KB | middle | 60 | 81.6 | 88.1 | 125.2 | 125.2 | 16.6 | 71.3 | 0 | True |
| giant | 51 KB | end | 60 | 78.8 | 80.5 | 86.0 | 86.0 | 16.4 | 64.9 | 0 | True |
| giant | 102 KB | start | 60 | 183.3 | 315.3 | 899.5 | 899.5 | 35.6 | 286.4 | 60 | True |
| giant | 102 KB | middle | 60 | 157.6 | 176.7 | 281.9 | 281.9 | 30.9 | 146.3 | 60 | True |
| giant | 102 KB | end | 60 | 150.2 | 154.9 | 165.3 | 165.3 | 30.5 | 126.0 | 60 | True |
| giant | 256 KB | start | 60 | 480.1 | 947.6 | 8699.9 | 8699.9 | 72.6 | 881.1 | 60 | True |
| giant | 256 KB | middle | 60 | 413.4 | 447.6 | 480.3 | 480.3 | 72.2 | 376.4 | 60 | True |
| giant | 256 KB | end | 60 | 378.4 | 390.8 | 576.9 | 576.9 | 75.0 | 316.8 | 60 | True |
| giant | 1 MB | start | 9 | 1542.1 | 28274.4 | 28274.4 | 28274.4 | 351.0 | 27971.9 | 9 | True |
| giant | 1 MB | middle | 27 | 1532.2 | 1588.6 | 1625.9 | 1625.9 | 290.3 | 1309.3 | 26 | True |

### Building blocks (median of 3), ms

Before TK-011 a keystroke paid for the first three columns and the diff; after it, only for planning against the storage. A snapshot copies the document and is paid on save, not per keystroke.

| Shape | Size | backend text copy | compare equal | planner prepare | text diff | snapshot |
|---|---|---|---|---|---|---|
| swift | 41 KB | 0.1 | 0.1 | 0.002 | — | 0.1 |
| swift | 1 MB | 2.8 | 2.8 | 0.002 | — | 2.7 |
| swift | 10 MB | 31.7 | 49.2 | 0.002 | — | 35.9 |
| swift | 100 MB | 318.6 | 314.5 | 0.003 | — | 330.2 |
| mixed | 10 MB | 29.1 | 29.2 | 0.002 | — | 28.9 |
| short | 10 MB | 31.0 | 28.2 | 0.002 | — | 30.6 |
| giant | 51 KB | 0.1 | 0.1 | 0.002 | — | 0.1 |
| giant | 102 KB | 0.3 | 0.3 | 0.002 | — | 0.3 |
| giant | 256 KB | 0.7 | 0.7 | 0.002 | — | 0.7 |
| giant | 1 MB | 3.0 | 2.8 | 0.002 | — | 2.8 |

### Scrolling (jump + layout+draw), ms

| Shape | Size | to end | to middle | to start | caret in view (end/middle/start) |
|---|---|---|---|---|---|
| swift | 41 KB | 9.4 | 10.4 | 6.5 | True/True/True |
| swift | 1 MB | 10.8 | 10.6 | 7.2 | True/True/True |
| swift | 10 MB | 18.2 | 19.5 | 19.5 | True/True/True |
| swift | 100 MB | 11.6 | 8.4 | 7.7 | True/True/True |
| mixed | 10 MB | 10.0 | 11.2 | 7.0 | True/True/True |
| short | 10 MB | 10.0 | 8.6 | 6.9 | True/True/True |
| giant | 51 KB | 50.2 | 48.6 | 25.0 | True/True/True |
| giant | 102 KB | 97.6 | 131.8 | 50.9 | True/True/True |
| giant | 256 KB | 242.1 | 242.7 | 117.7 | True/True/True |
| giant | 1 MB | 978.9 | 966.0 | 462.4 | True/True/True |

### Margin: line numbers for the rows in view (median of 5), ms

| Shape | Size | lines | start | middle | end | rows labelled (start/middle/end) | 1000 lookups | index = fresh scan, rebuilds |
|---|---|---|---|---|---|---|---|---|
| swift | 41 KB | 1538 | 0.056 | 0.073 | 0.073 | 40/41/40 | 0.32 | True, 0 |
| swift | 1 MB | 38020 | 0.056 | 0.060 | 0.058 | 40/41/40 | 0.40 | True, 0 |
| swift | 10 MB | 380133 | 0.061 | 0.069 | 0.069 | 40/41/40 | 0.99 | True, 0 |
| swift | 100 MB | 3801089 | 0.061 | 0.072 | 0.076 | 40/41/40 | 2.74 | True, 0 |
| mixed | 10 MB | 368156 | 0.061 | 0.075 | 0.067 | 40/41/40 | 0.50 | True, 0 |
| short | 10 MB | 3495255 | 0.058 | 0.066 | 0.068 | 40/41/40 | 0.75 | True, 0 |
| giant | 51 KB | 1 | 0.003 | 0.003 | 0.003 | 1/1/1 | 0.02 | True, 0 |
| giant | 102 KB | 1 | 0.003 | 0.003 | 0.003 | 1/1/1 | 0.03 | True, 0 |
| giant | 256 KB | 1 | 0.003 | 0.003 | 0.003 | 1/1/1 | 0.02 | True, 0 |
| giant | 1 MB | 1 | 0.003 | 0.003 | 0.003 | 1/1/1 | 0.02 | —, — |

### Programmatic edit, undo, redo, save, ms (p50 unless noted)

| Shape | Size | apply | undo | redo | save #1 | save #2 | changes rebuilt = view | changes (reconciled) |
|---|---|---|---|---|---|---|---|---|
| swift | 41 KB | 0.4 | 5.4 | 5.3 | 4.3 | 1.5 | True | 204 (0) |
| swift | 1 MB | 0.4 | 5.4 | 5.4 | 8.8 | 5.7 | True | 204 (0) |
| swift | 10 MB | 0.5 | 5.8 | 5.6 | 57.5 | 46.2 | True | 204 (0) |
| swift | 100 MB | 0.5 | 5.7 | 5.8 | 573.2 | 458.0 | True | 204 (0) |
| mixed | 10 MB | 0.5 | 6.7 | 6.9 | 47.6 | 46.2 | True | 204 (0) |
| short | 10 MB | 0.5 | 5.7 | 5.7 | 48.4 | 48.9 | True | 204 (0) |
| giant | 51 KB | 0.4 | 78.1 | 78.2 | 60.1 | 2.3 | True | 204 (0) |
| giant | 102 KB | 0.5 | 150.7 | 150.3 | 117.7 | 2.7 | True | 204 (192) |
| giant | 256 KB | 0.5 | 386.1 | 383.8 | 310.4 | 3.3 | True | 204 (192) |

### Memory, MB

| Shape | Size | text bytes | after open | end of run | peak resident |
|---|---|---|---|---|---|
| swift | 41 KB | 0.0 | 12 | 29 | 102 |
| swift | 1 MB | 1.0 | 17 | 42 | 108 |
| swift | 10 MB | 10.0 | 72 | 135 | 183 |
| swift | 100 MB | 100.0 | 643 | 667 | 868 |
| mixed | 10 MB | 10.0 | 72 | 124 | 206 |
| short | 10 MB | 10.0 | 135 | 212 | 309 |
| giant | 51 KB | 0.1 | 40 | 71 | 180 |
| giant | 102 KB | 0.1 | 44 | 209 | 246 |
| giant | 256 KB | 0.3 | 87 | 504 | 1118 |
| giant | 1 MB | 1.0 | 432 | — | — |
