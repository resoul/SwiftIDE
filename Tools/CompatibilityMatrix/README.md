# TK-009: Xcode / BSP compatibility matrix

Tools that ask SourceKit-LSP the same four questions (diagnostic, hover, definition, completion) about the fixtures in `Fixtures/`, with and without a build server, and record the answers. The findings are in [docs/11_COMPATIBILITY_MATRIX.md](../../docs/11_COMPATIBILITY_MATRIX.md).

| File | What it is |
|---|---|
| `make_xcodeproj.py` | Writes the `.xcodeproj` files of `Fixtures/MacApp`, `IOSApp`, `Workspace` (`MACAPP_EXTRA=` adds a source file, `MACAPP_DEFAULT_CONFIG=Debug` switches the default configuration) |
| `lsp_probe.py CASE.json` | One session of `sourcekit-lsp` on a fixture; `--restart` asks everything again after a restart; `--present NAME=true\|false` states which diagnostic must (not) appear |
| `scenario_probe.py` | Live scenarios on a running server: `new-file`, `config-switch` |
| `bsp_ask.py ROOT FILE` | Speaks BSP directly to the build server of `ROOT/buildServer.json`, without sourcekit-lsp |
| `cost_probe.py CASE.json OUT` | Memory of the process tree under sourcekit-lsp while it works |
| `write_build_server.py` | Writes `buildServer.json` for `sourcekit-xcode-bsp` (its `init` is interactive) |
| `guard_tree.py` | Kills a command's whole process tree over a memory/time limit (8 GB machine) |
| `cases/*.json`, `results/*.json` | The questions and the recorded answers |

## Build servers (not committed)

Cloned into `vendor/` (ignored by git), pinned:

```bash
git clone https://github.com/slime-studio/sourcekit-xcode-bsp.git vendor/sourcekit-xcode-bsp   # 726ce70 (0.1.0)
git clone https://github.com/SolaWing/xcode-build-server.git vendor/xcode-build-server          # 438d0ae (v1.3.0-11)
cd vendor/sourcekit-xcode-bsp && python3 ../../guard_tree.py 5500 2400 swift build -c release -j 2   # ~5 min, ~1.3 GB
```

`xcode-build-server` is used as a script and needs nothing built; for a fixture:

```bash
xcodebuild -project MacApp.xcodeproj -scheme MacApp -configuration Debug -derivedDataPath /tmp/dd build \
  | python3 vendor/xcode-build-server/xcode-build-server parse
```

## Repeating a measurement

```bash
python3 Tools/CompatibilityMatrix/make_xcodeproj.py
python3 Tools/CompatibilityMatrix/write_build_server.py Fixtures/MacApp xcode-bsp MacApp.xcodeproj macosx
python3 Tools/CompatibilityMatrix/lsp_probe.py Tools/CompatibilityMatrix/cases/macapp.json --restart \
  --present configurationProbeDebugOnly=false --present configurationProbeReleaseOnly=true
python3 Tools/CompatibilityMatrix/summarize_probe.py Tools/CompatibilityMatrix/results/*.json
```

Note on `results/macapp-xcodebsp-debug.json`: it expected the Debug-only diagnostic and did not get it, because the server uses the project's default configuration (Release); that is a finding, not a probe failure.
