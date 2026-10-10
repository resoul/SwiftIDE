# TK-013: truncated display of long lines — compatibility evaluation (before any implementation)

Date: 2026-10-10. Machine: Apple M2, 8 GB, macOS 27.0, release build, one run per row. Code: [Tools/Experiments/TruncatedDisplay](../../Tools/Experiments/TruncatedDisplay) (a throwaway AppKit probe, not part of any package). Context: [TK-012 step 2](TK-012-step2-prototype.md), [ADR-015](../07_ARCHITECTURE_DECISIONS.md). The question, as decided: show only the start of a very long line, keep the hidden part out of layout, keep the source text whole, start with reading only; before building it, check search, copy, selection and line numbering.

## Short conclusions

1. **The premise needs a correction.** For *reading*, plain TextKit 2 already copes with a single line far beyond our limits: laying out the whole document takes 11 ms at 100 KB, 66 ms at 1 MB, 313 ms at 5 MB and 630 ms at 10 MB, with peak memory 130 / 331 / 586 MB (1 / 5 / 10 MB), and scrolling to any offset works. What is slow is *editing* such a line (1533 ms per key at 1 MB, TK-012). In this probe no significant layout gain from truncation was found for reading (one run, no document session, bridge, real gutter or highlighter, so it does not establish the performance of the whole application). A read-only truncated view therefore is not justified by speed; what it would buy is **readability** (a 10 MB line is a document 1.9 million points tall; the start of the line plus "… N more characters" is a screen) and a bounded size of what is drawn.
2. **The simplest mechanism does not work.** Replacing the long paragraph through `NSTextContentStorageDelegate` with a shorter `NSTextParagraph` is cheap (2 ms at 100 KB, 13 ms at 5 MB) but the element keeps its full range while its text is shorter, and TextKit's navigation goes wrong: from offset 10 a single "move right" lands in the next line, "move left" from the next line jumps to the line before the long one, and "extend selection right" ×12 selects 100 423 characters. Geometry of the fragment is computed from the *shorter* length (65..<2092 instead of 65..<102466).
3. **A mechanism with consistent ranges works for reading,** with caveats: split the paragraph into two elements with true ranges (the start, and the hidden rest) and give the hidden one an empty layout fragment. Layout is cheap and independent of the hidden length (8 ms at 100 KB, 61 ms at 1 MB, 299 ms at 5 MB), the document is 544 points tall instead of 18 416 / 182 400 / 927 120, and caret movement, hit-testing, copy and select-all behave as in plain TextKit except at the cut (below). But its memory is **not** lower than plain: 252 MB at 1 MB and 940 MB at 5 MB (plain: 130 and 331), because the content storage still builds the whole paragraph on every enumeration. At 5 MB, before autorelease pools were drained per step, the probe passed 1.5 GB and was killed by its guard.
4. **What does not work with any hiding mechanism, by construction:** anything that needs geometry for the hidden text — a find highlight, scroll to a match, the caret or selection drawn there. `firstRect(forCharacterRange:)` is empty, text segments are empty, `scrollRangeToVisible` does nothing. They need an explicit way to reveal the line.

**Decision (2026-10-10, by the user): option 1 — keep the warning and the ordinary reading mode; truncation is not implemented for now.** The text below is the recommendation made before that decision.

**Recommendation:** do not build a performance-motivated read-only truncation; if the goal is readability, build the two-element mechanism as a *display option for read-only windows only*, with an explicit "Show full line" that switches that line (or the window) to plain layout, and treat memory as the thing to measure again on the real pipeline. If the goal is *editing* long lines, this evaluation does not help: it needs the editable variant, which is where the earlier prototype hung. The options are at the end.

## Results

Document: 5 short lines, one line of N KB (words, wrapped at 760 pt), 5 short lines. "Mode 0" plain TextKit 2; "mode 1" content-storage delegate substitution (visible 2000 characters + a notice); "mode 2" two elements with true ranges, the hidden one with an empty `NSTextLayoutFragment` subclass. Read-only text view.

### Layout and memory

| | 100 KB | 1 MB | 5 MB | 10 MB |
|---|---|---|---|---|
| mode 0: `ensureLayout(documentRange)` | 11 ms | 66 ms | 313 ms | 630 ms |
| mode 0: document height (pt) | 18 416 | 182 400 | 927 120 | 1 858 032 |
| mode 0: peak memory | – | 130 MB | 331 MB | 586 MB |
| mode 1: layout | 2.3 ms | – | 12.6 ms | – |
| mode 2: layout | 8.1 ms | 61 ms | 299 ms | – |
| mode 2: document height (pt) | 544 | 544 | 544 | – |
| mode 2: peak memory (pools drained per step) | – | 252 MB | 940 MB | – |

Peaks are the outer guard's sampling (every 0.3 s), so approximate. The 10 MB row of modes 1 and 2 was not run: mode 2 at 5 MB was already near the limit that is reasonable on this machine.

### Behaviour, 100 KB line, visible part 2000 characters

| | Mode 0 (plain) | Mode 1 (delegate) | Mode 2 (two elements) |
|---|---|---|---|
| Element / fragment range of the long line | 65..<102466 | element 65..<102466, **fragment 65..<2092** | 65..<2065 and 2065..<102466 |
| Rows of the long line | 1140 | 23 | 23 and 0 |
| Selection model: `setSelectedRange` in the hidden part | works | works | works |
| Geometry (`firstRect`, text segments) of hidden offsets | yes | none | none |
| `scrollRangeToVisible(hidden offset)` | scrolls (y 0 → 1102) | no effect | no effect |
| Copy of a selection across the cut | stored text | stored text | stored text |
| Select all + copy | whole document | whole document | whole document |
| Move right ×6 from offset 10 | 11…16 | **102402…102407** | 11…16 |
| Move right ×14 from 12 before the cut | continues 1989…2002 | **jumps to the next line** | continues 1989…2002 (the caret enters the hidden part, nothing is drawn) |
| Move left ×4 from the start of the next line | 102400…102397 | **−1, −2, … (before the long line)** | 102400…102397 |
| Shift+right ×12 from 10 before the cut | 12 characters | **100 423 characters** | 12 characters |
| Move to end of line from the start | 88 (visual row) | 88 | 88 |
| Move to end of paragraph | 102400 | 102400 | **2000 (stops at the cut)** |
| Move by word near the cut | 1993, 2001, 2009 | jumps to the next line | 1993, **2000**, 2001, 2009 |
| Hit test at the right side of the last row | 102400 | 102400 | 2000 |
| Accessibility character count / visible range | full / correct | full / **wrong** | full / **wrong** |

## Compatibility with what was asked

| Area | Verdict |
|---|---|
| **Copy** | Works in all modes: copy and select-all take the text from storage, so the hidden part **is copied**. This keeps "the source stays whole" but may surprise a user who sees only a start. A product decision: copy what is shown, or all (suggest: all, with the notice stating the line is longer). |
| **Selection** | The model is right in mode 2; drawing is absent over the hidden part. Moving the caret right through the cut enters a part that cannot be seen; the caret and selection must be handled there (skip the hidden part as one step, or draw the selection on the notice). Paragraph commands stop at the cut (as in TK-012 step 2) and need overrides in `CodeTextView`. Mode 1 is not usable. |
| **Search** | Searching the string finds matches in the hidden part, but there is no geometry to highlight and no scroll. A find UI needs to know a match is hidden and reveal the line first. Not run with `NSTextFinder` itself (the probe is headless); the verdict follows from the empty geometry. |
| **Line numbering** | By construction compatible: the gutter ([LineNumberRulerView](../../Packages/IDE/Sources/EditorUI/LineNumberRulerView.swift)) numbers a line by the start offset of its layout fragment (`lineStarting(at:)`), and those starts are intact in mode 2 (65, 2065, 102466 …); the hidden fragment has no rows and is skipped. In mode 1 the fragment range is shortened but its start is intact too. Not executed against the real ruler; the check is by reading the code and the fragment table above. |
| **Editing, undo, IME** | Not evaluated: the first version is read-only by decision. The TK-012 hang appeared with line-break edits; whether the two-element variant has it is unknown. |
| **Large lines in the real pipeline** | Not measured: the probe has no session, bridge, ruler or highlighter. |

## What the numbers say about the design

- The cost of mode 2 is not layout but the content storage: each enumeration builds the entire original paragraph before it is cut. Memory then follows the line length (about 190× at 5 MB). A real version would have to avoid creating the full paragraph, which means replacing `NSTextContentStorage`'s element generation rather than post-processing it — a larger change than the probe.
- Because plain read-only layout is already fast, a window for reading huge lines could also simply be **plain TextKit with the existing "Make Read-Only"** and a limit on how tall the view may be. That is the cheapest alternative to compare against.

## Not checked

`NSTextFinder` and the Find bar; mouse drag selection across the cut; the drawing of a notice in the hidden fragment (the probe's fragment draws nothing); VoiceOver; Retina rendering; 10 MB for modes 1 and 2; any run on another macOS or with the system's TextKit 1 fallback; repeated runs (one run per cell).

## Options

1. **Stop here.** Keep step 1 (warning and "Make Read-Only"); long lines remain readable in plain TextKit up to the 8 MB document limit; editing them stays slow.
2. **Readability only:** build the two-element mechanism for read-only windows, notice drawn in the hidden fragment, "Show full line", find reveals the line. Needs a content-storage that does not materialise the full paragraph; measure memory on the real pipeline first.
3. **Editing long lines:** a separate effort (display model per line with expansion, as in VS Code); this evaluation only rules out the delegate substitution.
