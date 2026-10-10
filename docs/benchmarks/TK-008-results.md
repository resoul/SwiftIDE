# TK-008: TextKit editor measurements at 1 / 10 / 100 MB and a giant line

> **Correction (2026-10-09).** The "middle" and "end" measurements in this report measured the top of the document: the text view could not grow above its initial height, and the window did not scroll. The commit cost and the O(edit) conclusion remain valid; the layout+draw figures for middle and end are wrong. The fix and the recalculation: [TK-007a](TK-007a-results.md).

Date: 2026-10-09. Tool: [Tools/Benchmarks/TextKitBenchmarks](../../Tools/Benchmarks/TextKitBenchmarks) (release build). Raw data: [TK-008-results.json](TK-008-results.json); tables built by `Tools/Benchmarks/summarize.py`.

**Bench:** Apple M2, 8 GB, macOS 27.0, Swift 6.4. One run of each scenario.

## Short conclusions

1. **TextKit itself copes with ordinary code at any size.** Opening 100 MB takes 0.78 s, drawing the visible part ≈ 4–5 ms, a jump to the start/middle/end ≤ 6 ms, and all of this barely depends on file size.
2. **Typing breaks our pipeline, not TextKit.** Keystroke latency grows linearly: ≈ 5 ms (41 KB) → ≈ 20 ms (1 MB) → ≈ 160 ms (10 MB) → ≈ 1.3–1.9 s (100 MB). It is fully explained by three operations over the whole text (a copy from the backend, a comparison, a check of the exact edit): at 10 MB 28 + 28 + 72 ≈ 128 ms against measured 132–190 ms. The p95 budget of ≤ 16 ms is already broken at 1 MB. Programmatic edits and undo are also O(n): 350 and 270 ms at 10 MB. The fix is [ADR-012](../07_ARCHITECTURE_DECISIONS.md) / TK-011.
3. **The giant line is a problem of TextKit itself.** Layout of the paragraph goes through in full: ≈ 1.3 ms per KB of the line for each keystroke and for opening. The 16 ms budget is exceeded already at a line of ≈ 10–12 KB; a 1 MB line — opening 1.3 s, a keystroke 1.6 s, individual layouts of 30 s. Our pipeline is almost irrelevant here: its O(n) part at a 1 MB line costs ≈ 13 ms (copy 3.0 + comparison 2.8 + planner 6.8), the whole commit p95 is 315 ms (the rest is TextKit's work on the edit), layout p95 is 1,331 ms.
4. **Memory ≈ 6.4–6.5× the file size after opening** (100 MB → 645 MB, 10 MB → 64 MB) and up to 1.5 GB after a series of edits on 100 MB.

## What was measured and how

Each scenario is a separate process (a hard timeout), the real application path: `AtomicDocumentFileStore.read` → `TextKitEditorFactory` → `DocumentSession` → window → typing via `NSTextView.insertText` (shouldChange → storage → bridge → session → publication) → drawing. Fixtures: Swift-like text with Cyrillic and emoji (LF), the same with mixed CRLF/CR, 10 MB of short lines (3.5 million paragraphs), one line without line breaks. 60 keystrokes each at the start, middle and end of the file; undo, redo, programmatic edit, two saves; scrolling.

"input→draw" = `insertText` (including our pipeline) + synchronous layout and drawing of the visible area into a bitmap. This is a lower-bound estimate of the delay to the screen: the real drawing through the compositor adds up to a frame.

### Outcome

| Shape | Size | Lines | Finished | Wall, s | Last phase reached |
|---|---|---|---|---|---|
| swift | 41 KB | 1538 | yes | 1.5 | summary |
| swift | 1 MB | 38020 | yes | 5.2 | summary |
| swift | 10 MB | 380133 | yes | 39.2 | summary |
| swift | 100 MB | 3801089 | yes | 216.5 | summary |
| mixed | 10 MB | 355461 | yes | 39.3 | summary |
| short | 10 MB | 3495255 | yes | 28.8 | summary |
| giant | 51 KB | 1 | yes | 18.1 | summary |
| giant | 102 KB | 1 | yes | 35.3 | summary |
| giant | 256 KB | 1 | yes | 100.2 | summary |
| giant | 1 MB | 1 | timeout | 242.1 | typing |

### Opening (read → editor → session → first layout+draw), ms

| Shape | Size | read | make editor | session | first layout+draw | total | footprint after open, MB |
|---|---|---|---|---|---|---|---|
| swift | 41 KB | 0.2 | 17.6 | 0.2 | 24.7 | 42.7 | 11 |
| swift | 1 MB | 1.6 | 10.2 | 2.7 | 25.3 | 39.9 | 18 |
| swift | 10 MB | 13.8 | 34.4 | 28.5 | 24.5 | 101.2 | 64 |
| swift | 100 MB | 161.2 | 285.5 | 314.0 | 19.4 | 780.1 | 645 |
| mixed | 10 MB | 14.2 | 37.4 | 27.8 | 19.5 | 99.0 | 64 |
| short | 10 MB | 10.6 | 10.6 | 30.5 | 15.4 | 67.0 | 50 |
| giant | 51 KB | 0.2 | 21.9 | 0.2 | 83.9 | 106.2 | 40 |
| giant | 102 KB | 0.3 | 7.0 | 0.4 | 143.4 | 151.0 | 44 |
| giant | 256 KB | 0.6 | 9.7 | 0.8 | 317.8 | 328.8 | 87 |
| giant | 1 MB | 1.7 | 11.9 | 3.0 | 1261.3 | 1277.9 | 275 |

### Typing: input → commit → layout+draw, ms (60 keystrokes per place)

| Shape | Size | Where | n | p50 | p95 | p99 | max | commit p95 | layout+draw p95 | reconciled |
|---|---|---|---|---|---|---|---|---|---|---|
| swift | 41 KB | start | 60 | 5.0 | 5.4 | 11.6 | 11.6 | 1.5 | 4.0 | 0 |
| swift | 41 KB | middle | 60 | 5.2 | 5.8 | 6.7 | 6.7 | 1.9 | 4.0 | 0 |
| swift | 41 KB | end | 60 | 4.9 | 5.0 | 5.1 | 5.1 | 1.4 | 3.7 | 0 |
| swift | 1 MB | start | 60 | 17.4 | 18.3 | 23.9 | 23.9 | 14.2 | 4.2 | 0 |
| swift | 1 MB | middle | 60 | 20.1 | 20.5 | 21.0 | 21.0 | 16.7 | 3.8 | 0 |
| swift | 1 MB | end | 60 | 22.7 | 24.9 | 26.3 | 26.3 | 20.7 | 4.3 | 0 |
| swift | 10 MB | start | 60 | 133.8 | 136.9 | 185.6 | 185.6 | 132.3 | 4.6 | 0 |
| swift | 10 MB | middle | 60 | 162.1 | 164.2 | 170.6 | 170.6 | 160.1 | 4.2 | 0 |
| swift | 10 MB | end | 60 | 188.5 | 189.7 | 191.9 | 191.9 | 185.8 | 4.1 | 0 |
| swift | 100 MB | start | 31 | 1285.7 | 1327.7 | 1434.2 | 1434.2 | 1323.2 | 4.7 | 0 |
| swift | 100 MB | middle | 26 | 1567.1 | 1596.0 | 1653.3 | 1653.3 | 1592.0 | 4.2 | 0 |
| swift | 100 MB | end | 22 | 1842.0 | 1915.4 | 1932.9 | 1932.9 | 1911.1 | 4.4 | 0 |
| mixed | 10 MB | start | 60 | 133.9 | 142.4 | 187.6 | 187.6 | 138.0 | 4.5 | 0 |
| mixed | 10 MB | middle | 60 | 160.4 | 165.7 | 234.4 | 234.4 | 161.6 | 4.1 | 0 |
| mixed | 10 MB | end | 60 | 187.9 | 188.6 | 192.2 | 192.2 | 184.7 | 4.0 | 0 |
| short | 10 MB | start | 60 | 86.3 | 88.0 | 94.3 | 94.3 | 83.7 | 4.4 | 0 |
| short | 10 MB | middle | 60 | 115.0 | 117.3 | 119.5 | 119.5 | 113.2 | 4.2 | 0 |
| short | 10 MB | end | 60 | 141.6 | 143.7 | 189.3 | 189.3 | 139.8 | 4.0 | 0 |
| giant | 51 KB | start | 60 | 95.3 | 133.7 | 216.9 | 216.9 | 15.3 | 119.0 | 0 |
| giant | 51 KB | middle | 60 | 79.6 | 83.2 | 85.9 | 85.9 | 15.3 | 68.1 | 0 |
| giant | 51 KB | end | 60 | 77.8 | 82.0 | 132.0 | 132.0 | 17.0 | 66.0 | 0 |
| giant | 102 KB | start | 60 | 186.9 | 313.1 | 908.8 | 908.8 | 29.9 | 284.9 | 0 |
| giant | 102 KB | middle | 60 | 155.7 | 163.7 | 184.3 | 184.3 | 29.1 | 134.9 | 0 |
| giant | 102 KB | end | 60 | 149.0 | 151.8 | 152.7 | 152.7 | 30.1 | 122.0 | 0 |
| giant | 256 KB | start | 55 | 487.9 | 1177.7 | 9054.8 | 9054.8 | 74.3 | 1108.5 | 0 |
| giant | 256 KB | middle | 60 | 421.4 | 459.9 | 473.7 | 473.7 | 74.1 | 388.1 | 0 |
| giant | 256 KB | end | 60 | 380.5 | 386.3 | 391.1 | 391.1 | 74.7 | 311.9 | 0 |
| giant | 1 MB | start | 6 | 1578.2 | 32871.3 | 32871.3 | 32871.3 | 306.0 | 32576.5 | 0 |
| giant | 1 MB | middle | 26 | 1579.7 | 1629.5 | 1629.5 | 1629.5 | 315.1 | 1331.2 | 0 |

### What one keystroke pays for (median of 3), ms

| Shape | Size | backend text copy | compare equal | planner prepare | text diff | snapshot |
|---|---|---|---|---|---|---|
| swift | 41 KB | 0.1 | 0.1 | 0.3 | 0.2 | 0 |
| swift | 1 MB | 2.8 | 2.7 | 6.9 | 4.9 | 0 |
| swift | 10 MB | 27.7 | 28.2 | 72.4 | 48.4 | 0 |
| swift | 100 MB | 298.0 | 280.2 | 721.1 | 481.5 | 0 |
| mixed | 10 MB | 27.7 | 28.1 | 71.4 | 48.4 | 0 |
| short | 10 MB | 30.6 | 28.1 | 36.8 | 50.3 | 0 |
| giant | 51 KB | 0.1 | 0.1 | 0.3 | 0.2 | 0 |
| giant | 102 KB | 0.3 | 0.3 | 0.7 | 0.5 | 0 |
| giant | 256 KB | 0.7 | 0.7 | 1.7 | 1.0 | 0 |
| giant | 1 MB | 3.0 | 2.8 | 6.8 | 4.1 | 0 |

### Scrolling (jump + layout+draw), ms

| Shape | Size | to end | to middle | to start |
|---|---|---|---|---|
| swift | 41 KB | 4.4 | 4.9 | 3.6 |
| swift | 1 MB | 4.5 | 4.5 | 3.5 |
| swift | 10 MB | 5.0 | 4.3 | 3.4 |
| swift | 100 MB | 4.9 | 4.3 | 3.4 |
| mixed | 10 MB | 4.5 | 4.9 | 3.5 |
| short | 10 MB | 4.4 | 4.5 | 3.8 |
| giant | 51 KB | 24.5 | 24.6 | 24.1 |
| giant | 102 KB | 45.1 | 45.4 | 45.8 |
| giant | 256 KB | 110.2 | 111.0 | 111.3 |
| giant | 1 MB | 454.4 | 456.2 | 451.9 |

### Programmatic edit, undo, redo, save, ms (p50 unless noted)

| Shape | Size | apply | undo | redo | save #1 | save #2 | view = session after undo |
|---|---|---|---|---|---|---|---|
| swift | 41 KB | 1.6 | 5.0 | 4.9 | 9.8 | 1.6 | True |
| swift | 1 MB | 36.1 | 31.1 | 31.0 | 6.9 | 5.4 | True |
| swift | 10 MB | 352.1 | 272.8 | 273.1 | 22.4 | 17.5 | True |
| swift | 100 MB | 3506.2 | 2679.5 | 2693.3 | 170.7 | 139.2 | True |
| mixed | 10 MB | 351.3 | 273.2 | 273.1 | 21.3 | 17.6 | True |
| short | 10 MB | 325.0 | 180.3 | 181.0 | 19.6 | 16.4 | True |
| giant | 51 KB | 2.3 | 77.8 | 77.8 | 51.9 | 2.0 | True |
| giant | 102 KB | 4.2 | 152.5 | 152.7 | 93.9 | 76.2 | True |
| giant | 256 KB | 10.0 | 385.8 | 385.4 | 250.8 | 193.8 | True |

### Memory, MB

| Shape | Size | text bytes | after open | end of run | peak resident |
|---|---|---|---|---|---|
| swift | 41 KB | 0.0 | 11 | 18 | 90 |
| swift | 1 MB | 1.0 | 18 | 36 | 108 |
| swift | 10 MB | 10.0 | 64 | 137 | 206 |
| swift | 100 MB | 100.0 | 645 | 1476 | 1493 |
| mixed | 10 MB | 10.0 | 64 | 137 | 216 |
| short | 10 MB | 10.0 | 50 | 116 | 187 |
| giant | 51 KB | 0.1 | 40 | 87 | 205 |
| giant | 102 KB | 0.1 | 44 | 183 | 376 |
| giant | 256 KB | 0.3 | 87 | 793 | 1408 |
| giant | 1 MB | 1.0 | 275 | — | — |

## Analysis

### Opening
1,000 lines (41 KB) open in ≈ 43 ms out of a 100 ms budget. This is a warm process; a cold start of the application was not measured. For 100 MB: reading 161 ms, creating the editor 286 ms, session initialisation 314 ms (text copy), first layout 19 ms — 0.78 s in total. The file is visible immediately; layout runs lazily only over the visible area.

### Typing
Layout and drawing are constant (4 ms). `native commit` grows exactly like the sum of "what a keystroke pays": this is our code. The full publication happens exactly once per keystroke (`published_versions` = the number of keystrokes, `reconciled` = 0 everywhere).

| Size | Input p95 | Fits in 16 ms |
|---|---|---|
| 41 KB | 5–6 ms | yes |
| 1 MB | 18–25 ms | no |
| 10 MB | 137–190 ms | no |
| 100 MB | 1.3–1.9 s | no |

A linear estimate of ≈ 20 ms per MB gives 16 ms at roughly **0.5–0.7 MB** (interpolation, not a direct measurement). For 100 ms — about 4–5 MB (also interpolation).

### Undo, programmatic edit, saving
Undo/redo go through a diff of two strings, programmatic edit goes through `Array(utf16)`; both are O(n): 270 and 350 ms at 10 MB, 2.7 and 3.5 s at 100 MB. Saving is cheap because it is a single pass: 22 ms at 10 MB and 170 ms at 100 MB (reading for verification, SHA-256, write, `fsync`, `rename`). After undo the session text matched the view text in all scenarios.

### Giant line
Layout time is linear in the length of the line (≈ 1.3 ms/KB), so opening, the jump (≈ 0.45 µs per byte) and every keystroke all grow. The first keystroke at the start of the line after switching is especially heavy: 9 s at 256 KB and 33 s at 1 MB (p99/max); after that the keystrokes take the time usual for the size. The 1 MB scenario exceeded the 242 s timeout (the "end of file", undo and save phases did not run). The 10 MB and 100 MB scenarios with a line were **deliberately not run**: on 8 GB they would have pushed the machine into swap. Linear extrapolation (not a measurement): opening ≈ 13 s and ≈ 2.8 GB for 10 MB; at 100 MB — cannot be opened.

> **Update.** The conclusions about typing, programmatic edit and undo below refer to the pipeline before [ADR-012](../07_ARCHITECTURE_DECISIONS.md). After TK-011 they no longer hold: see [TK-011](TK-011-results.md). The conclusions about the giant line and memory after opening still stand.

## Proposed limits (for the current build)

| Parameter | Value | Basis |
|---|---|---|
| Comfortable editing within the 16 ms budget | up to ≈ 0.5 MB | interpolation from 41 KB and 1 MB |
| Acceptable (< 100 ms per keystroke) | up to ≈ 4 MB | interpolation |
| Opening and reading | up to 100 MB works technically (0.8 s, 645 MB) | measured |
| Editing above 10 MB | unusable (0.16–1.9 s per keystroke) | measured; removed by TK-011 |
| Length of one line | up to ≈ 10 KB within the budget; above 100 KB unusable; 1 MB — view only | measured |

Decisions based on the results:
- I am not changing the 100 MB opening limit until TK-011 is re-measured: reading and viewing at this size are good; only editing is bad, because of our code.
- TK-011 (ADR-012) is done before TK-007 and LSP: the gutter, highlighting and sync with SourceKit depend on cheap editing.
- Long lines are a separate task: detect on opening, warn, then a long-line mode (splitting a paragraph for layout through a custom `NSTextContentManager` — a hypothesis that needs an experiment; or view-only without editing). I am not deciding on a custom backend for this item yet: there is no data on the alternatives.

## Limitations of the measurement and caveats

- One run per scenario, one machine (M2, 8 GB), no repeats: the spread between runs for memory is noticeable. Comparing the 100 MB runs: final memory 0.9 GB and 1.5 GB, peak 1.3 and 1.5 GB. Input latencies between runs agree to within ±5% (10 MB: p95 165–190 ms).
- Keystrokes are synthetic (`insertText`), without dispatching real events and without an input method; undo groups are closed by running the run loop after each keystroke.
- Window 900×640, monospace 13 pt, line wrapping on (`widthTracksTextView`); without wrapping the behaviour of long lines may differ. Not checked: scroll wheel, VoiceOver, several documents, cold start, completion.
- The phase time limit is 40 s: at 100 MB 22–31 keystrokes were typed instead of 60.
- **A corrected methodology error.** The first run did not release the autorelease pool between keystrokes, which on the giant line gave a memory growth of ≈ 7 MB per keystroke (up to 4.8 GB with a 1 MB file). Those numbers were discarded; the document uses the data of the second run (a pool per keystroke, protection against going above 3 GB). Latencies did not change between the runs.
- Memory — the process's `phys_footprint`; peak — `ru_maxrss`.

## Repeat

```sh
swift build -c release --package-path Tools/Benchmarks/TextKitBenchmarks
Tools/Benchmarks/TextKitBenchmarks/.build/release/TextKitBenchmarks driver docs/benchmarks/TK-008-results.json
python3 Tools/Benchmarks/summarize.py docs/benchmarks/TK-008-results.json
```

A full run takes about 10 minutes and uses up to 1.5 GB of memory; do not run other load in parallel, or the numbers will be distorted. One scenario: `TextKitBenchmarks run <swift|mixed|short|giant> <MB> [seconds per phase]`. Run lines longer than 1 MB only on a machine with enough memory headroom.
