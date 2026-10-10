# Support for Bazel projects

**Status:** the direction was accepted on 2026-10-10 ([ADR-023](07_ARCHITECTURE_DECISIONS.md#adr-023-support-for-bazel-projects)). The integration is not implemented or verified. The current routing of language services looks for the nearest `Package.swift`; a Bazel file without such a package goes to the shared service for single files.

The goal of the first slice is to open an already configured Bazel workspace and get language features for Swift through SourceKit-LSP and `sourcekit-bazel-bsp`. Support for C/C++/Objective-C/Objective-C++ is accepted separately under the [mixed-language plan](12_MIXED_LANGUAGE_SUPPORT.md), and BSP setup, Build/Test, run and debugging have stages of their own.

## Basis and upstream requirements

`sourcekit-bazel-bsp` is a BSP bridge between Bazel and SourceKit-LSP. Upstream declares language features for Swift, Objective-C and C++; the Build/Run/Test/debug UI is provided by a separate Cursor/VSCode extension. These statements are not results of a SwiftIDE check. [README](https://github.com/spotify/sourcekit-bazel-bsp)

According to the README as read on 2026-10-10: using it requires a Swift 6.1+ toolchain (Xcode 16.4+), and building the BSP itself lists Xcode 26. The authors recommend the SourceKit-LSP they ship or a suitable one of your own: some of the capabilities used may still be missing from the Xcode distribution. Apple development needs the Xcode SDK and tools. The compatibility of concrete versions is fixed in the spike; the minimum upstream requirements do not replace our matrix.

The project must be set up for indexing; upstream warns about WMO. The `setup_sourcekit_bsp` rule sets targets, the Bazel wrapper and flags, and creates `.bsp/skbsp.json` and `.sourcekit-lsp/config.json`. We check a ready configuration rather than assume that BSP is always discovered through `buildServer.json`. [The setup rule](https://github.com/spotify/sourcekit-bazel-bsp/blob/main/rules/setup_sourcekit_bsp.bzl)

## Shared project context (TK-018)

The document language (TK-015) and the project type are independent values: a Swift file may belong to SwiftPM, Xcode or Bazel. The build settings belong to the selected project context, not to the file extension.

| Part of the context | Target contract |
|---|---|
| Project type | SwiftPM, Xcode/BSP, Bazel, a compilation database or single files |
| Root | An explicitly opened workspace takes priority; project discovery must not silently switch it to a nested package |
| Build choice | For Bazel — labels/a set of targets and the configuration; for Xcode — scheme/config/destination; for SwiftPM — the package and the applicable settings |
| Tools | The selected SourceKit-LSP, SDK/toolchain, BSP and Bazel wrapper; paths and versions are visible in the project state |
| Revision | A change of root, targets, configuration or tools invalidates requests/diagnostics of the previous context without changing the text version |
| Lifetime | One service per selected project context; all its documents share the connection; the processes terminate when the scope is closed/on exit |

Discover a Bazel workspace by `MODULE.bazel` and a prepared BSP configuration. The old `WORKSPACE`/`WORKSPACE.bazel` are treated as candidates, compatibility is checked separately. A single `BUILD.bazel` does not determine the repository root. If several build systems are present in a directory at once, use a saved explicit choice or offer to choose the context.

Domain/Application describe the values and the state of the project without the Bazel CLI, BSP JSON and AppKit. The concrete discovery, configuration check and tool calls belong to the project/build adapters. The existing text storage, completion UI, ordered transport and stale rejection are reused. These are target boundaries; creating a new set of targets before the need is verified is not required.

## The first slice: an already configured workspace

The user opens the repository root with a working `sourcekit-bazel-bsp` setup. SwiftIDE checks the tool paths and the configuration, launches the selected SourceKit-LSP in this context, opens documents and shows the state of preparation/indexing. BSP is launched through SourceKit-LSP; do not create a second independent BSP client without need.

Support choosing the path to SourceKit-LSP per project instead of a mandatory `xcrun --find sourcekit-lsp`. The choice of the binary and of the SDK/toolchain is checked as one compatible configuration. At the first stage the already installed tools are used; installing and shipping binaries is a separate decision after the spike.

UI states: checking the setup → launch → target preparation/indexing → available language features; on a failure — the reason and an available action. Partial readiness is allowed: the availability of features is determined for the current document/target, not by waiting for the full index of the repository. Check progress notifications, timeout/cancellation, restart and recovery of open documents. Editing and local highlighting are available on any service error.

The initial fixture is a small Swift Bazel project with two related targets. Check completion, hover/definition and diagnostics on unsaved text; show that a dependency's API is visible through the real compiler settings. After that, extend the matrix of mixed languages and platforms.

## Later stages

| Task | Scope | Exit criterion |
|---|---|---|
| TK-018 | Shared project context | The type/root/targets/toolchain and the revision are shared by the language and build services; a nested `Package.swift` does not intercept a Bazel workspace |
| TK-019 | Spike SourceKit-LSP + Bazel BSP | Pinned versions and a reproducible fixture; real answers, bootstrap/restart and known limitations; a go/no-go decision |
| TK-020 | Experimental language features | Open a configured workspace → get completion → jump into a dependency → see a diagnostic; states, timeouts and process closing work |
| TK-021 | BSP setup from SwiftIDE | Choosing targets/wrapper/index flags, viewing the proposed changes, running the setup and re-checking; the project's existing settings are kept |
| TK-022 | Bazel Build/Test | Choosing the target/config, saving before the run, a streaming result, cancellation and a jump to the error; a separate acceptance with no dependency on the VSCode extension |

Running on a simulator, managing simulators and debugging through LLDB are the next backlog with a separate estimate. Editing BUILD/`.bzl` with highlighting and Starlark completion is also accepted separately from the language features of Swift/the C family.

Design TK-018 next to TK-015; TK-019 can be run on Swift before all the TK-016 grammars are finished. TK-020 requires TK-018, a successful TK-019 and the fixing/acceptance of the shared completion workflows of TK-014. The other languages are connected under TK-017; TK-021/TK-022 do not block the first slice.

A guide for one developer: **2–5 working days for the spike**, then **1–3 weeks for a limited integration of the language features** with a compatible fixture. This is a provisional estimate before launch, without Build/Test, Run/debug, tool installation and a wide matrix; the results of the spike must refine it. The work is not automatically part of the earlier 12–22 weeks of alpha.

## Checks and risks

- Record macOS/Xcode/Swift, SourceKit-LSP, BSP, Bazel/wrapper and the versions of the project rules, targets and index flags. Compare the chosen LSP distribution with the Xcode toolchain; record the actual limitations rather than declaring all versions compatible.
- A cold launch without a cache and reopening: the time to the language features, completion trigger → popup, memory/disk use and the indexing of the selected targets. Start with a small set of targets instead of the whole repository.
- Swift/C/ObjC/C++/ObjC++: each combination of language, platform and target is accepted separately; generated headers/sources, module maps, includes/defines and jumps between languages are checked before/after a build.
- A change of BUILD/`.bzl`/`MODULE.bazel`, of the set of targets and of the index flags: the context is updated and there are no old answers; changing the setup parameters requires re-running the setup under the upstream workflow.
- Paths with spaces, Bazel symlinks/execution root and generated files: definition/diagnostics open the right file; URIs do not create a second document session.
- An LSP/BSP crash, a hung preparation, cancellation and closing the workspace: a bounded wait, a clear state and termination of the processes owned by the scope, child processes included. Check the behaviour of the long-lived Bazel server separately.
- The indexing and the user's builds: the correct platform, output base and cache; do not enable experimental modes of a shared cache/output base without a separate run. An indexing failure does not damage the user's build.
- Setup: changes to `MODULE.bazel`, BUILD and the generated config are visible before applying; re-running the setup keeps the user's parameters and does not turn into a hidden rewrite of the project.

All the results are published in the [compatibility matrix](11_COMPATIBILITY_MATRIX.md), the limitations in the release notes. Until it is checked Bazel has the status "planned", after the first accepted slice — "experimental" for a specific configuration. [Risks](06_QUALITY_AND_RISKS.md), [future manual acceptance](10_MANUAL_ACCEPTANCE.md).
