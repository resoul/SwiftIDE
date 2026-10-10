# Truncated display probe (TK-013)

A throwaway probe, not shipped and not part of any package build. It checks what TextKit 2 does
when only the start of a long paragraph is laid out and the text storage stays whole. Results and
conclusions: [docs/benchmarks/TK-013-compatibility.md](../../../docs/benchmarks/TK-013-compatibility.md).

```bash
cd Tools/Experiments/TruncatedDisplay
swift build -c release
./guarded.sh 1500 100 .build/release/truncprobe <KB> <mode>   # mode 0 plain, 1 delegate substitution, 2 two elements
```

Always run it through the guard (memory limit in MB, time limit in seconds): the machine has 8 GB.
`LIMIT=n` sets how many characters stay visible (default 2000). The process also ends itself
after 90 seconds.
