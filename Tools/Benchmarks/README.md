# Benchmarks

`TextKitBenchmarks` measures the real editor pipeline (file store → session → bridge → `NSTextView`) on generated files of 40 KB to 100 MB, plus single-line files. Results and analysis for TK-008: [docs/benchmarks/TK-008-results.md](../../docs/benchmarks/TK-008-results.md).

```sh
swift build -c release --package-path Tools/Benchmarks/TextKitBenchmarks
Tools/Benchmarks/TextKitBenchmarks/.build/release/TextKitBenchmarks driver docs/benchmarks/TK-008-results.json
python3 Tools/Benchmarks/summarize.py docs/benchmarks/TK-008-results.json
```

Run it alone: other load distorts the numbers. A full run takes about ten minutes and uses up to 1.5 GB. Single-line files over 1 MB are not part of the matrix on purpose; they exhaust memory on an 8 GB machine. Only build in release configuration.
