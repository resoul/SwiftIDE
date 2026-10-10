# TK-012: long lines, step 1 — detection and warning

Date: 2026-10-10. Same bench (Apple M2, 8 GB, macOS 27.0, release; keystrokes via `insertText`, drawing into a bitmap). Data: [TK-012-long-lines.json](TK-012-long-lines.json). Decision — [ADR-015](../07_ARCHITECTURE_DECISIONS.md).

## Short conclusions

1. **Do not turn off line wrapping: without it, things are worse.** A giant 51 KB line: typing takes 84 ms with wrapping and 257 ms without; 102 KB: 158 and 696 ms; a 256 KB line without wrapping did not finish in several minutes. Opening without wrapping is also slower (51 KB: 257 → 337 ms, 102 KB: 214 → 715 ms). Scrolling to the end without wrapping is slightly faster (44 vs 83 ms), but editing is the reason this work exists. Wrapping stays.
2. **Ordinary typing in a line exceeds the budget at about 16,000 characters:** 12,000 characters — p95 9.3 ms, 16,000 — 14.7 ms, 24,000 — 33 ms (at 8,000 — 9.6 ms). Below ≈ 4,000 characters the cost stays within 5.4–6.4 ms. A single paragraph is laid out in full, so the cost grows with line length, not with file size.
3. **The "long line" threshold is 16,000 characters** (UTF-16, without a line break): this is the point where typing stops fitting into a 16 ms p95 with some margin. For colours the thresholds are lower and separate (ADR-014): 1000 characters and 50 coloured runs.
4. **Finding the longest line is cheap:** the line index stores the longest line of each chunk; the query costs one step per chunk (≈ 7,400 chunks for 100 MB), not one per line; it can be run after every edit.

## What is implemented in step 1

- `LineIndex.longestLine` and `LongLinePolicy` (threshold 16,000), `LongLineMonitor`: checks the longest line after every change; states `normal` / `warning` / `dismissed`; the warning is shown once, is cleared when the line becomes shorter, and does not come back after "Keep Editing".
- A banner above the text (`NoticeBanner` in `EditorContainerView`): "This file has a line of N characters. Editing long lines can be slow, and syntax colours are off for them." Buttons **Make Read-Only** (the window becomes non-editable, the subtitle shows "read-only", the banner changes to "Allow Editing") and **Keep Editing**. By default the file opens for editing, as decided.
- Tests: `LongLineMonitorTests` (5), `NoticeBannerTests` (2), the longest-line query checked against a model on random edits (`LineIndexTests`). Checked by mutations (the `>` boundary, the warning returning after "Keep Editing").

## Not done and not verified

- **Editing a long line itself is still slow:** step 1 only warns. Step 2 (a prototype that splits a long line into pieces for layout only, through a custom content manager) is a separate, time-boxed experiment; the result is unknown.
- The window with the warning was not opened in the live app (File → Open with a real file): the banner was verified by a test, by snapshots of the banner in light and dark themes, and by building the app. Added to the manual acceptance checklist.
- Read-only currently works only at the view level (`isEditable = false`): programmatic edits of the session are not blocked; saving is allowed.
- The threshold is based on one measurement on one machine and on synthetic lines (numbers separated by commas); real minified files are structured differently.
- Word wrapping in a long line without spaces (minified JS) was not measured.
