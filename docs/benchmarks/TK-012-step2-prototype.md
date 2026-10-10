# TK-012, step 2: prototype that splits a long line for layout

Date: 2026-10-10. Bench: Apple M2, 8 GB, macOS 27.0, release. Data: [TK-012-step2-prototype.json](TK-012-step2-prototype.json). Code: [Tools/Experiments/LongLineSplit](../../Tools/Experiments/LongLineSplit). Context: [ADR-015](../07_ARCHITECTURE_DECISIONS.md).

## Short conclusions

1. **The idea works and gives a huge gain.** A subclass of `NSTextContentStorage` hands TextKit a long paragraph as several `NSTextParagraph` objects (the text in storage does not change). Typing in one line of 1 MB: **1533 → 21 ms** (p50), at 256 KB: 466 → 17 ms, at 51 KB: 76 → 14 ms. At 5 MB — 43 ms, at 10 MB — 70 ms (the cost grows with size, because the pieces are rebuilt in full on every edit).
2. **But the prototype cannot be adopted: a hang was found.** In a random test (typing, deleting, Enter and joining lines, scrolling, moving the caret, IME), TextKit goes into an endless layout loop, and memory grows by a gigabyte within seconds. With line-break edits this happens in 2 of 6 runs (earlier, on an unbalanced test, 3 of 6); without them, 0 of 6; plain TextKit on the same seeds — 0 of 3. That means pressing Enter or Backspace in a long line can freeze the editor. I did not find the cause; three mitigations did not help (see below).
3. **Even without a hang, the behaviour differs** in four places (below), and two of them are visible to the user.

Verdict: **not suitable for the product in its current form.** Step 1 (the warning and "read-only") remains the only protective mechanism. The decision on what comes next is yours; the options are at the end.

## How the prototype works and what turned out to be non-trivial

`enumerateTextElements(from:options:using:)` is overridden: a native paragraph longer than a piece is cut into parts, each one an `NSTextParagraph` with its own `elementRange`, `paragraphContentRange` and `paragraphSeparatorRange`. It turned out that all of the following are needed; without any one of them the process crashed or hung:
- **Pieces must stay alive as long as TextKit remembers them.** A layout fragment holds the element without owning it; a temporary piece is freed, and the next access crashes in `objc_msgSend` on a garbage address. Pieces are cached by generation (the last three).
- **`paragraphContentRange` and `paragraphSeparatorRange` are required**, and for a native paragraph the separator is an empty range at the end, not `nil`; with `nil` the code crashes in `compare:`.
- **`from:` and `.reverse` must be respected.** The first version ignored the starting location and returned pieces from the start of the paragraph: the caret moved with `moveRight` from the second piece jumped to position 1, and with `moveLeft` to the end of the document. That was a bug in the probe, not in TextKit.
- **Cut on a character boundary**, not inside a surrogate pair or a composed character (otherwise `moveRight` gets stuck on an emoji). The cut is made after a space in the back half of the window, otherwise on the boundary of a composed sequence.
- **The return value** of `enumerateTextElements` is the stopping point; when it stops inside a long paragraph, this is the edge of the piece, not the end of the paragraph.
- Cutting on every enumeration (≈ 40 per keystroke) cost roughly 65 of 89 ms at 1 MB (an estimate from summed counters); the cache sped it up almost fourfold (89 → 24 ms).

Piece size: the minimum is around 2–4 KB (1 MB, p50: 512 → 35.7; 1024 → 26.3; **2048 → 23.7**; 4096 → 25.4; 8192 → 39.7 ms).

An attempt to leave the elements alone and cut only the **layout fragments** via the `NSTextLayoutManager` delegate (a fragment may cover part of an element) gave no gain: 1 MB — 1357 ms; TextKit still lays out the element in full.

## What works the same as without splitting

The same commands from 60–76 starting positions around piece boundaries, on a fresh view for each, plain TextKit against splitting (pieces of 256 for frequent boundaries; text with spaces; and a long line among ordinary lines):

Identical: left/right, by word, all four variants with selection extension, delete backward/forward/by word, select word, select paragraph, delete to start/end of paragraph, to the start/end of the document. Caret geometry (275 offsets, including boundaries) and hit-testing on click — no differences. The text after edits across boundaries matches the model. IME (`setMarkedText`) inside a piece and on a boundary works. `scrollRangeToVisible` to any offset shows it.

## What differs without the hang

| | Plain TextKit | Splitting |
|---|---|---|
| Visual line | wraps by width | **breaks at the piece boundary**: the document is 7% taller (pieces of 2048) and 22% (256); a "short tail" is visible every ≈ 2 KB |
| ↑/↓, Cmd+←/→ (visual lines) | by wrapped lines | the same, but the line ends at the piece edge |
| Ctrl+A/E, Option+↑/↓ with selection (**paragraphs**) | to the start/end of the logical line | **stop at the piece edge** (four commands) |
| Words in a line without spaces | run across the whole "syllable" | stop at the piece edge |

The paragraph commands can be overridden in `CodeTextView` (we own the class), but that is ≈ 8 selectors; selecting a paragraph with the command (`selectParagraph`) matched the plain one, but I did not check a triple click.

## The hang: what is known

- Stack at the moment of the hang: `layoutViewport → ensureLayoutForBounds → _estimatedTextLocationForVerticalOffset…` in an endless repetition of `enumerateTextElements(from: X)` with the same `X` (the start of an ordinary paragraph next to the cut one). Each call yields all elements up to the end of the document and returns its end, and the layout manager calls it again.
- It depends on line-break edits (Enter/Backspace in the cut paragraph): 2 of 6 against 0 of 6 without them, with a document of ≈ 19 KB.
- Did not help: returning the real stopping point; respecting `from:`; **a full layout invalidation when the paragraph count changes** (3 of 6 still loop). Not checked: element height estimates (`estimatedIntrinsicContentSize`) and consistency of old layout fragments after paragraphs are merged as a cause; replacing not only the elements but the whole `NSTextContentStorage`; a different `NSTextLayoutManager`.
- Without `MallocScribble` the same run grows just the same (> 1 GB), so the cause is not the debug allocator. The first background stress runs drove the system into memory exhaustion (a macOS message), so the stress now runs only through the guard ([guarded.sh](../../Tools/Experiments/LongLineSplit/guarded.sh)), which kills the process when it grows above the limit.

## Not checked

Undo and redo through the real undo coordinator; line numbers in the left gutter (`LineNumberRulerView` over the pieces); colours (`SyntaxPresenter`; long lines have none by policy); NSTextFinder; accessibility (VoiceOver); mouse-drag selection across boundaries; load when paging. The probe is AppKit-only, without the session, bridge or gutter; the numbers do not include their cost (from the difference of the "shelves" — 4.5 ms in the probe and 5.4–6.4 ms in the main bench on short lines — it is on the order of 1–2 ms; not measured directly). One run per row of the table, one machine.

## Options

1. **Stop at step 1.** Change nothing in the editor; long lines get a warning and "read-only".
2. **Find the cause of the hang and finish the prototype.** The scope is unknown: it would require digging into TextKit's layout internals; in any case it needs a guard against endless layout and overrides of the paragraph commands, and the visual line breaks remain.
3. **A different approach, as VS Code does** (as far as I remember, there is a setting "don't render a line beyond N characters"; I have not checked): do not draw the tail of a line longer than the threshold, show "…", and allow editing only after expanding it. This changes the display model but does not touch TextKit's internals; the decision is yours.
