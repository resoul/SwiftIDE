# TK-007b: how to colour text — rendering attributes or attributes in storage

Date: 2026-10-09. The bench and method are the same as in [TK-007a](TK-007a-results.md) (Apple M2, 8 GB, macOS 27.0, release, keystrokes via `insertText`, drawing into a bitmap). Raw data: [TK-007b-results.json](TK-007b-results.json). Decision — [ADR-014](../07_ARCHITECTURE_DECISIONS.md), section 007b.

This is a prototype with the **cost of applying colour**, not highlighting: the colours come from a synthetic "highlighter" (words of three or more characters are coloured cyclically in four colours: 2.6 ranges per line in the generated Swift, 3748 on the 51 KB giant line). There is no parsing; it comes in 007c.

## Short conclusions

1. **Approach 1, rendering attributes, was chosen** (`NSTextLayoutManager.renderingAttributesValidator` + `setRenderingAttributes`). It does not touch the text, `editGeneration`, revisions or undo (checked by tests and measurement), colours move with the text during edits, and the validator is called lazily, only for fragments that TextKit lays out (≈ 40 out of 380 thousand lines).
2. **The cost on ordinary lines does not depend on file size.** Typing with colouring, p95 "input → draw": 8.6–9.5 ms for 41 KB…100 MB (without colouring 6.2–6.7). Refreshing the colours of the whole visible area: ≈ 10 ms (40 fragments, ≈ 110 ranges), of which 0.3 ms is in the validator itself.
3. **Storage attributes are cheaper by ≈ 1 ms per keystroke** (7.6–8.4 ms against 8.6–9.5) and almost as expensive when refreshing an area (≈ 10 ms). That does not outweigh the rest: they change the storage (typed text inherits the colour of its neighbour, with possible side effects on marked text and paste), and the colours have to be re-added by hand on every scroll. If approach 1 proves unreliable, this is the fallback, and it is measured.
4. **Long lines are expensive with either approach, and rendering is worse.** The 51 KB giant line: typing 490 ms (rendering) and 290 ms (storage) against 84 ms without colour; 102 KB: 911 and 406 ms against 160. So colouring of lines tens of KB is turned off (the line-length threshold will be set in 007c, based on these figures), not optimised.
5. **The main limitation of the mechanism.** Fragments that are already drawn are recoloured only by a notification about a change of storage attributes (`NSTextStorage.edited(.editedAttributes, range:, changeInLength: 0)`): `invalidateRenderingAttributes`, `invalidateLayout` and `setNeedsDisplay` did not update anything in a live window (checked from a snapshot of the window taken with `screencapture`). The notification **must name a range**: over the whole document it is not lazy (see below).

## What was checked and how

| Property | Check |
|---|---|
| Colour is drawn; version, `editGeneration` and undo do not change | the automated test `renderingAttributesColourTextWithoutTouchingTheDocument` (bitmap) and the measurement: `untouched` = True for both approaches in all scenarios |
| Colours follow edits; typed text inside a word is plain and splits the word | `renderingAttributesFollowEditsAndTypedTextStartsPlain` |
| The validator is called only for laid-out fragments | `theValidatorIsAskedOnlyForWhatIsLaidOut`: fewer than 400 calls for 20,000 lines; in the measurement 40–42 |
| An edit inside a coloured fragment keeps the colour | `typingInAColouredFragmentKeepsItColoured` |
| An attribute-change notification recolours its range and creates no revision | `anAttributeOnlyNotificationRevalidatesItsRangeWithoutARevision`, `aRefreshOfOneLineLeavesTheOthersAsTheyWere`; checked by a mutation (without the notification the tests fail) |
| Recolouring reaches fragments far from the visible area | in the live window with snapshots: after changing the colour and sending a notification for the whole text, the top, middle and bottom of a 3000-line file took the new colour (a temporary probe, not an automated test: it needs screen access) |

## Notification over the whole document

In the preliminary run (with the validator enabled) a notification over the whole text took **45 ms at 41 KB, 1.3 s at 1 MB and 59 s at 10 MB**; at 100 MB I stopped it. These numbers are in [TK-007b-preliminary-results.json](TK-007b-preliminary-results.json) (except for 10 MB: I wrote its value down when the run was stopped, and it is not in the file). In the final matrix the same edit costs 9–10 ms, but there is no validator and no colours there any more, so there is nothing to recalculate. The conclusion: the cost lies in the fact that the notification makes TextKit lay out and check the fragments of the whole document again, not in the notification itself. For 007c: only the named range can be recoloured (the visible area ≈ 10 ms at any size), and the rest should be marked as stale and updated once it enters the visible area.

## About the preliminary run

The first run of the matrix gave a commit p95 ≈ 40 ms at 1 MB when typing with colour. The cause was the order in the scenario: the "whole document" measurement came before typing and left the whole text invalidated. The measurement was moved to the end of the scenario and the matrix was rebuilt completely; there is no such effect in the final data (commit p95 ≈ 1 ms).

## Not checked

- The validator and updates during IME composition (marked text): there are no automated tests for it; it goes into the manual acceptance. Until it is checked, updates are not performed while `session.isComposing`.
- The behaviour of `edited(.editedAttributes)` is observed, not documented; it is pinned by automated tests and by a check in the live window on macOS 27.0. On other versions it must be checked at acceptance; the fallback (storage attributes) is measured.
- The real colours of the themes, contrast and dark mode for the tokens themselves; VoiceOver.
- The cost of real parsing (007c): it is not included here.

## Limitations

One run per scenario, one machine, synthetic keystrokes, a bitmap; synthetic ranges are simpler than real ones. For the 41 KB file in the base set the "middle" showed once a p95 of 11.8 ms (p99 23 ms) — an outlier; the other sizes have none.

## Full tables

### Outcome

| Shape | Size | Lines | Finished | Wall, s | Last phase reached |
|---|---|---|---|---|---|
| swift | 41 KB | 1538 | yes | 3.3 | summary |
| swift | 1 MB | 38020 | yes | 3.1 | summary |
| swift | 10 MB | 380133 | yes | 4.3 | summary |
| swift | 100 MB | 3801089 | yes | 16.6 | summary |
| mixed | 10 MB | 355461 | yes | 4.3 | summary |
| short | 10 MB | 3495255 | yes | 4.1 | summary |
| giant | 51 KB | 1 | yes | 63.6 | summary |
| giant | 102 KB | 1 | yes | 108.6 | summary |
| giant | 256 KB | 1 | yes | 99.7 | summary |
| giant | 1 MB | 1 | timeout | 242.2 | typing |

### Opening (read → editor → session → first layout+draw), ms

| Shape | Size | read | make editor | session | line index | first layout+draw | total | footprint after open, MB |
|---|---|---|---|---|---|---|---|---|
| swift | 41 KB | 0.2 | 40.7 | 0.0 | 0.1 | 35.0 | 76.0 | 11 |
| swift | 1 MB | 1.6 | 9.9 | 0.0 | 1.0 | 27.8 | 40.3 | 17 |
| swift | 10 MB | 15.8 | 36.1 | 0.0 | 11.6 | 28.7 | 92.3 | 72 |
| swift | 100 MB | 180.2 | 284.5 | 0.0 | 123.0 | 23.0 | 610.6 | 743 |
| mixed | 10 MB | 14.2 | 35.6 | 0.0 | 10.5 | 27.3 | 87.5 | 72 |
| short | 10 MB | 10.7 | 8.5 | 0.0 | 25.7 | 21.5 | 66.4 | 135 |
| giant | 51 KB | 0.2 | 19.4 | 0.0 | 0.0 | 82.0 | 101.6 | 40 |
| giant | 102 KB | 0.3 | 53.9 | 0.0 | 0.1 | 148.1 | 202.4 | 48 |
| giant | 256 KB | 0.5 | 9.8 | 0.0 | 0.1 | 323.6 | 334.1 | 87 |
| giant | 1 MB | 1.8 | 11.3 | 0.0 | 0.5 | 1269.1 | 1282.7 | 281 |

### Typing: input → commit → layout+draw, ms (60 keystrokes per place)

| Shape | Size | Where | n | p50 | p95 | p99 | max | commit p95 | layout+draw p95 | reconciled | caret in view |
|---|---|---|---|---|---|---|---|---|---|---|---|
| swift | 41 KB | start | 60 | 5.8 | 6.6 | 12.2 | 12.2 | 1.0 | 5.5 | 0 | True |
| swift | 41 KB | middle | 60 | 6.0 | 11.8 | 23.3 | 23.3 | 1.3 | 7.5 | 0 | True |
| swift | 41 KB | end | 60 | 5.4 | 5.5 | 5.6 | 5.6 | 0.4 | 5.1 | 0 | True |
| swift | 41 KB | middle, rendering attributes | 60 | 8.8 | 9.3 | 10.1 | 10.1 | 1.1 | 8.3 | 0 | True |
| swift | 41 KB | middle, storage attributes | 60 | 7.4 | 8.4 | 11.5 | 11.5 | 1.3 | 7.4 | 0 | True |
| swift | 1 MB | start | 60 | 5.8 | 6.3 | 10.6 | 10.6 | 1.0 | 5.2 | 0 | True |
| swift | 1 MB | middle | 60 | 6.0 | 6.5 | 7.2 | 7.2 | 1.0 | 5.6 | 0 | True |
| swift | 1 MB | end | 60 | 5.6 | 6.1 | 6.2 | 6.2 | 0.5 | 5.7 | 0 | True |
| swift | 1 MB | middle, rendering attributes | 60 | 8.9 | 9.5 | 10.3 | 10.3 | 1.1 | 8.5 | 0 | True |
| swift | 1 MB | middle, storage attributes | 60 | 7.4 | 7.8 | 8.1 | 8.1 | 1.0 | 6.8 | 0 | True |
| swift | 10 MB | start | 60 | 5.8 | 6.8 | 10.7 | 10.7 | 1.1 | 5.7 | 0 | True |
| swift | 10 MB | middle | 60 | 6.0 | 6.2 | 6.6 | 6.6 | 0.7 | 5.5 | 0 | True |
| swift | 10 MB | end | 60 | 5.6 | 5.7 | 5.8 | 5.8 | 0.4 | 5.3 | 0 | True |
| swift | 10 MB | middle, rendering attributes | 60 | 8.4 | 8.7 | 9.7 | 9.7 | 0.9 | 7.9 | 0 | True |
| swift | 10 MB | middle, storage attributes | 60 | 7.4 | 7.6 | 7.9 | 7.9 | 0.9 | 6.7 | 0 | True |
| swift | 100 MB | start | 60 | 5.9 | 6.2 | 11.0 | 11.0 | 1.0 | 5.2 | 0 | True |
| swift | 100 MB | middle | 60 | 6.1 | 6.2 | 6.6 | 6.6 | 0.8 | 5.5 | 0 | True |
| swift | 100 MB | end | 60 | 5.7 | 5.9 | 6.2 | 6.2 | 0.4 | 5.5 | 0 | True |
| swift | 100 MB | middle, rendering attributes | 60 | 8.5 | 8.6 | 8.9 | 8.9 | 0.8 | 7.9 | 0 | True |
| swift | 100 MB | middle, storage attributes | 60 | 7.4 | 7.7 | 7.8 | 7.8 | 1.0 | 6.8 | 0 | True |
| mixed | 10 MB | start | 60 | 6.0 | 6.7 | 11.2 | 11.2 | 1.1 | 5.5 | 0 | True |
| mixed | 10 MB | middle | 60 | 6.2 | 6.4 | 6.7 | 6.7 | 0.9 | 5.6 | 0 | True |
| mixed | 10 MB | end | 60 | 5.6 | 5.7 | 6.2 | 6.2 | 0.4 | 5.3 | 0 | True |
| mixed | 10 MB | middle, rendering attributes | 60 | 9.0 | 9.2 | 9.3 | 9.3 | 1.1 | 8.2 | 0 | True |
| mixed | 10 MB | middle, storage attributes | 60 | 7.5 | 7.7 | 7.7 | 7.7 | 1.1 | 6.6 | 0 | True |
| short | 10 MB | start | 60 | 6.0 | 6.7 | 10.6 | 10.6 | 1.0 | 5.6 | 0 | True |
| short | 10 MB | middle | 60 | 6.1 | 6.7 | 7.3 | 7.3 | 0.8 | 5.9 | 0 | True |
| short | 10 MB | end | 60 | 5.7 | 5.9 | 5.9 | 5.9 | 0.4 | 5.5 | 0 | True |
| short | 10 MB | middle, rendering attributes | 60 | 6.1 | 6.4 | 6.9 | 6.9 | 0.8 | 5.6 | 0 | True |
| short | 10 MB | middle, storage attributes | 60 | 6.3 | 6.4 | 6.8 | 6.8 | 0.9 | 5.6 | 0 | True |
| giant | 51 KB | start | 60 | 94.9 | 152.8 | 184.9 | 184.9 | 16.0 | 137.4 | 0 | True |
| giant | 51 KB | middle | 60 | 81.0 | 85.2 | 87.7 | 87.7 | 16.5 | 69.6 | 0 | True |
| giant | 51 KB | end | 60 | 78.6 | 80.9 | 81.5 | 81.5 | 16.3 | 64.5 | 0 | True |
| giant | 51 KB | middle, rendering attributes | 60 | 457.4 | 489.5 | 530.8 | 530.8 | 227.4 | 254.3 | 0 | True |
| giant | 51 KB | middle, storage attributes | 60 | 198.9 | 288.8 | 461.7 | 461.7 | 42.6 | 244.4 | 0 | True |
| giant | 102 KB | start | 60 | 179.7 | 301.1 | 1126.3 | 1126.3 | 30.2 | 272.9 | 60 | True |
| giant | 102 KB | middle | 60 | 155.9 | 169.9 | 179.2 | 179.2 | 29.6 | 140.5 | 60 | True |
| giant | 102 KB | end | 60 | 149.3 | 156.0 | 203.6 | 203.6 | 29.9 | 126.5 | 60 | True |
| giant | 102 KB | middle, rendering attributes | 44 | 904.5 | 910.9 | 938.8 | 938.8 | 433.1 | 479.5 | 44 | True |
| giant | 102 KB | middle, storage attributes | 60 | 395.0 | 406.4 | 426.8 | 426.8 | 75.3 | 329.8 | 60 | True |
| giant | 256 KB | start | 60 | 469.5 | 941.9 | 8916.4 | 8916.4 | 71.4 | 871.8 | 60 | True |
| giant | 256 KB | middle | 60 | 413.7 | 461.5 | 496.9 | 496.9 | 74.6 | 383.6 | 60 | True |
| giant | 256 KB | end | 60 | 382.8 | 401.2 | 438.5 | 438.5 | 77.8 | 325.9 | 60 | True |
| giant | 1 MB | start | 9 | 1555.0 | 28722.5 | 28722.5 | 28722.5 | 353.8 | 28428.8 | 9 | True |
| giant | 1 MB | middle | 27 | 1554.1 | 1583.8 | 1590.6 | 1590.6 | 296.2 | 1289.0 | 26 | True |

### Building blocks (median of 3), ms

Before TK-011 a keystroke paid for the first three columns and the diff; after it, only for planning against the storage. A snapshot copies the document and is paid on save, not per keystroke.

| Shape | Size | backend text copy | compare equal | planner prepare | text diff | snapshot |
|---|---|---|---|---|---|---|
| swift | 41 KB | 0.1 | 0.1 | 0.002 | — | 0.1 |
| swift | 1 MB | 2.9 | 2.8 | 0.002 | — | 2.7 |
| swift | 10 MB | 28.6 | 28.5 | 0.003 | — | 28.1 |
| swift | 100 MB | 297.4 | 281.4 | 0.003 | — | 272.6 |
| mixed | 10 MB | 27.6 | 28.2 | 0.002 | — | 27.1 |
| short | 10 MB | 30.6 | 28.0 | 0.002 | — | 30.0 |
| giant | 51 KB | 0.2 | 0.2 | 0.002 | — | 0.1 |
| giant | 102 KB | 0.3 | 0.3 | 0.002 | — | 0.3 |
| giant | 256 KB | 0.7 | 0.7 | 0.002 | — | 0.7 |
| giant | 1 MB | 2.9 | 2.8 | 0.002 | — | 2.8 |

### Scrolling (jump + layout+draw), ms

| Shape | Size | to end | to middle | to start | caret in view (end/middle/start) |
|---|---|---|---|---|---|
| swift | 41 KB | 9.1 | 10.3 | 6.5 | True/True/True |
| swift | 1 MB | 9.4 | 10.4 | 6.5 | True/True/True |
| swift | 10 MB | 9.9 | 8.4 | 6.7 | True/True/True |
| swift | 100 MB | 10.4 | 8.4 | 6.7 | True/True/True |
| mixed | 10 MB | 9.5 | 10.8 | 6.7 | True/True/True |
| short | 10 MB | 10.0 | 8.6 | 6.9 | True/True/True |
| giant | 51 KB | 49.8 | 48.2 | 25.0 | True/True/True |
| giant | 102 KB | 102.7 | 94.0 | 46.8 | True/True/True |
| giant | 256 KB | 239.2 | 239.6 | 116.7 | True/True/True |
| giant | 1 MB | 967.6 | 962.9 | 467.9 | True/True/True |

### Margin: line numbers for the rows in view (median of 5), ms

| Shape | Size | lines | start | middle | end | rows labelled (start/middle/end) | 1000 lookups | index = fresh scan, rebuilds |
|---|---|---|---|---|---|---|---|---|
| swift | 41 KB | 1538 | 0.056 | 0.069 | 0.074 | 40/41/40 | 0.37 | True, 0 |
| swift | 1 MB | 38020 | 0.056 | 0.062 | 0.058 | 40/41/40 | 0.35 | True, 0 |
| swift | 10 MB | 380133 | 0.057 | 0.065 | 0.063 | 40/41/40 | 0.60 | True, 0 |
| swift | 100 MB | 3801089 | 0.058 | 0.073 | 0.086 | 40/41/40 | 0.56 | True, 0 |
| mixed | 10 MB | 368156 | 0.057 | 0.075 | 0.066 | 40/41/40 | 0.49 | True, 0 |
| short | 10 MB | 3495255 | 0.057 | 0.068 | 0.069 | 40/41/40 | 0.51 | True, 0 |
| giant | 51 KB | 1 | 0.003 | 0.003 | 0.003 | 1/1/1 | 0.02 | True, 0 |
| giant | 102 KB | 1 | 0.003 | 0.003 | 0.003 | 1/1/1 | 0.02 | True, 0 |
| giant | 256 KB | 1 | 0.003 | 0.003 | 0.003 | 1/1/1 | 0.02 | True, 0 |
| giant | 1 MB | 1 | 0.003 | 0.003 | 0.003 | 1/1/1 | 0.02 | —, — |

### Colours: refreshing what is in view, ms (typing with each approach is in the typing table)

Rendering attributes: a validator colours each fragment as it is laid out, refreshed with an attribute-only notification over the visible range. Storage: the same spans written into the text storage.

| Shape | Size | rendering start | middle | end | fragments / spans per refresh | in validator | storage start | middle | end | untouched (rendering / storage) | whole doc |
|---|---|---|---|---|---|---|---|---|---|---|---|
| swift | 41 KB | 10.1 | 10.4 | 9.8 | 41 / 116 | 0.34 | 10.3 | 9.9 | 9.7 | True / True | 10.2 |
| swift | 1 MB | 10.2 | 10.6 | 10.1 | 41 / 116 | 0.35 | 10.4 | 10.1 | 10.1 | True / True | 8.6 |
| swift | 10 MB | 10.3 | 10.2 | 10.0 | 42 / 105 | 0.34 | 10.4 | 10.0 | 10.1 | True / True | — |
| swift | 100 MB | 10.4 | 10.1 | 10.1 | 42 / 105 | 0.32 | 10.6 | 10.2 | 10.0 | True / True | — |
| mixed | 10 MB | 10.8 | 11.0 | 10.4 | 41 / 116 | 0.35 | 10.3 | 10.0 | 9.9 | True / True | — |
| short | 10 MB | 7.4 | 7.6 | 7.2 | 42 / 2 | 0.07 | 7.2 | 7.5 | 7.2 | True / True | — |
| giant | 51 KB | 184.4 | 184.6 | 185.4 | 1 / 3748 | 8.63 | 160.6 | 174.6 | 162.0 | True / True | 200.4 |
| giant | 102 KB | 372.4 | 371.2 | 366.7 | 1 / 7492 | 18.05 | 321.1 | 336.5 | 333.4 | True / True | 393.5 |

### Programmatic edit, undo, redo, save, ms (p50 unless noted)

| Shape | Size | apply | undo | redo | save #1 | save #2 | changes rebuilt = view | changes (reconciled) |
|---|---|---|---|---|---|---|---|---|
| swift | 41 KB | 0.4 | 5.3 | 5.3 | 8.7 | 1.9 | True | 324 (0) |
| swift | 1 MB | 0.4 | 5.4 | 5.4 | 7.4 | 5.6 | True | 324 (0) |
| swift | 10 MB | 0.4 | 5.4 | 5.4 | 44.7 | 43.1 | True | 324 (0) |
| swift | 100 MB | 0.5 | 5.6 | 5.5 | 411.0 | 414.3 | True | 324 (0) |
| mixed | 10 MB | 0.4 | 5.5 | 5.5 | 43.7 | 42.6 | True | 324 (0) |
| short | 10 MB | 0.5 | 5.7 | 5.7 | 48.1 | 46.5 | True | 324 (0) |
| giant | 51 KB | 0.4 | 77.3 | 77.1 | 56.4 | 2.2 | True | 324 (0) |
| giant | 102 KB | 0.5 | 150.3 | 149.9 | 112.1 | 2.6 | True | 308 (296) |
| giant | 256 KB | 0.5 | 378.2 | 377.4 | 292.5 | 3.9 | True | 204 (192) |

### Memory, MB

| Shape | Size | text bytes | after open | end of run | peak resident |
|---|---|---|---|---|---|
| swift | 41 KB | 0.0 | 11 | 38 | 111 |
| swift | 1 MB | 1.0 | 17 | 51 | 123 |
| swift | 10 MB | 10.0 | 72 | 143 | 215 |
| swift | 100 MB | 100.0 | 743 | 1207 | 1256 |
| mixed | 10 MB | 10.0 | 72 | 140 | 216 |
| short | 10 MB | 10.0 | 135 | 244 | 314 |
| giant | 51 KB | 0.1 | 40 | 328 | 394 |
| giant | 102 KB | 0.1 | 48 | 540 | 651 |
| giant | 256 KB | 0.3 | 87 | 716 | 1205 |
| giant | 1 MB | 1.0 | 281 | — | — |
