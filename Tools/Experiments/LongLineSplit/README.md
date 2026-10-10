# Long-line split experiment (TK-012, step 2)

A throwaway probe, not shipped and not part of any package build. It answers one question from
ADR-015: can a very long line be given to TextKit 2 in pieces, without changing the text, so that
editing it stays within the frame budget? Findings: [docs/benchmarks/TK-012-step2-prototype.md](../../../docs/benchmarks/TK-012-step2-prototype.md).

AppKit only. A plain `NSTextView` over a subclass of `NSTextContentStorage` whose
`enumerateTextElements` hands out a long paragraph as several `NSTextParagraph` pieces.

```bash
cd Tools/Experiments/LongLineSplit
swift build -c release
B=.build/release/splitprobe
$B <KB> <0|1>                    # typing in one long line: 0 = plain TextKit, 1 = split. PIECE=2048 sets the piece size
$B behave <0|1>                  # caret, selection, IME and scrolling checks
PIECE=256 $B diff [hard] [mixed] # the same editing commands near piece boundaries, plain against split
$B stress <seed> <operations>    # random edits, scrolling, caret moves, IME; checks the text against a model
```

Run the stress mode only through the guard, which kills a process that grows past a memory limit
or runs too long (the machine has 8 GB, and the stress mode can hang TextKit in an endless layout
loop that fills memory in seconds):

```bash
./guarded.sh 800 120 .build/release/splitprobe stress 4 500
```

Environment: `PIECE` (piece size, default 2048), `KEEP` (generations of pieces kept alive, default 3),
`NONEWLINE=1` (stress without Enter/Delete on line breaks), `PLAIN=1` (stress without splitting),
`INVALIDATE=1` (invalidate the whole layout when the paragraph count changes), `LINE_CHARS=n`
(break the generated text into lines of n characters), `TRACE=1`, `DUMP_AT=<step>`.
