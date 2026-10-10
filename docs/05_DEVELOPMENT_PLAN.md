# Current plan: TextKit 2 → a working IDE

## Conditions and estimate

One experienced Swift/macOS developer, full time; the starting OS target is macOS 15+, the toolchain matrix is closed by a spike. The first editor is NSTextView on TextKit 2. Custom storage/layout/rendering is not on the critical path.

The estimate for a sequential alpha: roughly **12–22 working weeks**, with no separate reserve for unknown Xcode/BSP problems and a wide beta. This is a guide, not a promise. **2–3 weeks** refer only to a limited native editor prototype, not to a finished IDE or to the whole of stage M1.

## Milestones

| Stage | Estimate | Result | Exit criterion |
|---|---|---|---|
| M0: compatibility and TextKit spike | 1–2 weeks | Xcode/BSP fixtures, explicit TK2, initial measurements | The toolchain is confirmed; the limits are known; one source of truth |
| M1: native editor + document lifecycle | 3–5 weeks | Window, open/edit/save, backend bridge, basic undo/IME, gutter | Native and programmatic edits create correct versions; save race/conflict checks |
| M2: language services | 2–4 weeks | Completion, diagnostics, hover/definition, syntax | Ordered sync, stale rejection, restart and read-only degraded states |
| M3: project and code checking | 2–4 weeks | Scheme/config/destination, build, Problems, simulator run | Verified SwiftPM and a set of Xcode fixtures; save-before-build, cancellation |
| M4: working alpha | 4–7 weeks | Palette/Quick Open/search, recovery, Git status, performance, accessibility | Pilot workflow; crash restore; IME/VoiceOver; release limitations |

The numbers M1–M4 here replace the old milestones. The old M2–M5 of the custom engine roadmap do not belong to the current MVP. Multi-cursor, split editor, complex folding and cross-file rename are the next backlog.

## First tasks

| ID | Task | State / criterion |
|---|---|---|
| TK-001 | Backend port + constructor DI | Present in Packages/IDE |
| TK-002 | TextKit storage/layout graph | Present; the native view in Packages/IDE uses the same graph |
| TK-003 | Versioned transactions and events | Present; native edits enter through the same session path (TK-005) |
| TK-004 | Explicit TextKit 2 NSTextView host | The factory/host/monitor and the Apps/SwiftIDE window are implemented; there are factory tests |
| TK-005 | Native input/undo/IME transaction bridge | A slice is implemented in Packages/IDE: preflight, reconciliation, one UndoManager, composition state, save gate. Manual acceptance of CJK IME/dead keys is still to come |
| TK-006 | Real open/save + disk revision policy | A slice is implemented: AtomicDocumentFileStore, FileRevision, registry, Open/Save in the application, conflict dialog. Save As is implemented (ADR-013). Recovery is implemented ([ADR-016](07_ARCHITECTURE_DECISIONS.md)): a delayed text snapshot, a question at launch, a conflict with the disk is kept. The watcher is implemented ([ADR-017](07_ARCHITECTURE_DECISIONS.md)): a clean document is re-read by itself, a modified one gets a Reload / Keep Mine bar, a deleted file gets a bar with Save As. Neither has been checked by hand in a window |
| TK-007 | Gutter + incremental syntax presentation | Done (manual acceptance of IME and the live window is ahead): 007a done ([measurements](benchmarks/TK-007a-results.md)), 007b done ([prototype](benchmarks/TK-007b-results.md): rendering attributes), 007c done ([tree-sitter](benchmarks/TK-007c-results.md)), design — [ADR-014](07_ARCHITECTURE_DECISIONS.md#adr-014-gutter-and-syntax-highlighting-tk-007): 007a line index and gutter, 007b attributes prototype, 007c tree-sitter; attributes do not create text revisions |
| TK-008 | Benchmark 1/10/100 MB and giant line | Done: [results](benchmarks/TK-008-results.md). Typing is O(file) in our pipeline (→ TK-011), a giant line runs into TextKit layout |
| TK-009 | Xcode/BSP fixture matrix | First slice done: [matrix](11_COMPATIBILITY_MATRIX.md), [ADR-019](07_ARCHITECTURE_DECISIONS.md) (accepted: xcode-build-server inside SwiftIDE with an embedded runtime, Xcode projects are experimental). Fixtures: SwiftPM / macOS / iOS simulator / a workspace with two projects, a package and a generated file; both BSP candidates work on Xcode 27 provided Build goes to the server's root. Not verified: the embedded Python (size, signing), Xcode 26, real projects, ObjC, test targets |
| TK-010 | Ordered SourceKit sync | Done as the `LanguageInfrastructure` module ([ADR-020](07_ARCHITECTURE_DECISIONS.md)): an ordered queue, edit ranges, resync on lag, restart, completion with rejection of stale answers; verified against a real sourcekit-lsp (Xcode 27.0). Hover/definition/diagnostics in the window are not done |
| TK-014 | Swift completion in the window | Implemented ([ADR-022](07_ARCHITECTURE_DECISIONS.md#adr-022-swift-completion-in-the-window-tk-014)): its own window under the caret without taking focus; after "." and on Ctrl+Space, Edit ▸ Complete, Esc, F5; choosing is one edit (one Undo); stale answers are dropped; the root is the nearest `Package.swift`. Tests and mutations passed, including against a real sourcekit-lsp. **Not verified in a live window and with a real IME** ([section K](10_MANUAL_ACCEPTANCE.md)); the server's replacement range is honoured; a status line in the window and a request timeout of 5 s are done. The latency to the menu has not been measured |
| TK-015 | Shared document language | Implemented ([ADR-024](07_ARCHITECTURE_DECISIONS.md#adr-024-the-document-language-in-one-place-tk-015)): one selector per document (manual choice → target context → file name), a language revision, Save As, the Edit ▸ Language menu; highlighting and the server follow it. The target context (TK-018) and the highlighting of other languages (TK-016) are not connected; not verified in a live window ([section M](10_MANUAL_ACCEPTANCE.md)) |
| TK-016 | Highlighting of C/C++/Objective-C/Objective-C++ | Implemented for C, C++ and Objective-C ([ADR-025](07_ARCHITECTURE_DECISIONS.md#adr-025-highlighting-of-c-c-and-objective-c-tk-016)): pinned grammars, generated queries, a rule for an unterminated `/*`; 9 tests, including SDK headers. **Objective-C++ is not supported** (no grammar reads the mixture without errors). Apple headers with `NS_OPTIONS` are read by the Objective-C grammar with errors (`NSString.h` 97%). Not verified in a live window ([section N](10_MANUAL_ACCEPTANCE.md)) |
| TK-017 | LSP of mixed projects | **Two slices done.** [ADR-026](07_ARCHITECTURE_DECISIONS.md#adr-026-the-c-family-on-sourcekit-lsp-first-slice-of-tk-017): completion of C/C++/Objective-C in a SwiftPM package and for documents without a file, Swift sees C/Objective-C targets. [ADR-027](07_ARCHITECTURE_DECISIONS.md#adr-027-symbol-description-jump-to-definition-and-diagnostics-in-the-window-tk-017-second-slice): symbol description (pointer and ⌃⇧Space), jump to definition (⌘-click, ⌃⌘J; another file in its own window), diagnostics (wavy line, dot in the margin, counter); end-to-end tests against a real server and through the window. Conditions: the package is built and is not in the system temporary folder. **Not done:** `compile_commands.json`, Xcode/BSP, Bazel, Swift/C++ interop, Objective-C++ on a real server, code actions; live acceptance (sections O, P). Choosing among several definitions and "Back" were done after the review |
| TK-018 | Shared project context | Still to come ([ADR-023](07_ARCHITECTURE_DECISIONS.md#adr-023-support-for-bazel-projects)): SwiftPM/Xcode/Bazel/compilation database, an explicit workspace, targets/config/toolchain and a context revision; design it next to TK-015. **Decisions from the review (2026-10-10), no implementation yet:** File ▸ Open Folder sets an explicit root, which takes priority over the nearest `Package.swift`; single files are opened as before, with automatic package detection. The target is determined by file membership, a choice is shown only when it is ambiguous; the context keeps the root, build system, target, configuration, toolchain and a revision. An explicit "prepare language features" command starts a build with progress, errors and cancellation (the press is the consent, no dialog; automatic preparation later, as a project setting). For temporary folders a discreet warning, the project is not moved. The context revision discards answers of the old configuration, but does not prove that the flags are ready: separate project preparation states are needed (check the background preparation modes and SourceKit-LSP's fallback to default settings on the shipped version). Order: manual acceptance K/M/N/O/P, then TK-018 |
| TK-019 | Spike SourceKit-LSP + Bazel BSP | Still to come: an already configured Swift fixture with a dependency, pins of LSP/BSP/Bazel/rules and flags; real completion/hover/definition/diagnostics, cold/warm indexing and a go/no-go |
| TK-020 | Language features of a Bazel workspace | Still to come after TK-018/019 and the acceptance of shared completion: an experimental slice on a ready BSP setup; the path to LSP, preparation status, timeout/cancellation, restart and scope termination |
| TK-021 | Setting up Bazel BSP from SwiftIDE | A later stage: targets/wrapper/index flags, viewing changes, setup that preserves the user's settings, and re-checking |
| TK-022 | Bazel Build/Test | A later stage: target/config, save-before-build, a streaming result, cancellation, jump to the error; Run/debug/simulator separately |
| TK-023 | Swift formatting and linting | Implemented ([result](14_CODE_STYLE_AND_LINTING.md#implementation-result)): pinned SwiftFormat 0.63.1 and SwiftLint 0.65.1 (SHA-256), `spacing-check` on SwiftSyntax 604 for blank lines before `return` and after a multi-line `if`, `lint.sh` / `format.sh` / `selftest.sh`, a CI workflow. Mass formatting was done in the working tree (105 files), the tests pass; **commit separately**. The workflow passed on the `xcode-27` runner (the first run on `macos-latest` failed: there is no Xcode 27 there) |
| TK-012 | Long-line mode | Step 1 done ([measurements](benchmarks/TK-012-long-lines.md), [ADR-015](07_ARCHITECTURE_DECISIONS.md)): detection and a warning with "Make Read-Only". Step 2 (a prototype of splitting a long line for layout) was carried out: [report](benchmarks/TK-012-step2-prototype.md). 1 MB: typing 1533 → 21 ms, but an infinite layout loop on Enter/Backspace next to a split line; not fit for the product. **Decided:** we stay at step 1, step 2 is not shipped, the cause of the hang is not being sought for now; next is a separate prototype of truncated display (TK-013) |
| TK-013 | Truncated display of long lines | **Decided: do not implement** (option 1: the warning and the ordinary reading mode remain). Compatibility assessment: [report](benchmarks/TK-013-compatibility.md). The probe found no significant layout gain when reading (one run without a session, bridge and a real gutter, so no conclusion about the speed of the whole application): plain TextKit 2 reads a line of up to 10 MB in 0.6 s. Substituting a paragraph through a delegate breaks the caret; two elements with honest ranges keep them, but the caret vanishes in the hidden part, the end of the paragraph stops at the cut, accessibility names a wrong visible range, memory at 5 MB is about three times the ordinary. Return to the question if editing long lines becomes necessary |
| TK-011 | Cost of a keystroke O(edit) instead of O(file) | Done: [re-measurement](benchmarks/TK-011-results.md), typing p95 ≈ 5 ms at any size up to 100 MB. What remains are long lines (TextKit) and main-thread blocking when saving large files |

## A separate direction: Bazel

[Bazel support](13_BAZEL_SUPPORT.md) is accepted: the shared project context TK-018 next to TK-015 → spike TK-019 → language features of a configured workspace TK-020 → setup TK-021 and Build/Test TK-022. The Swift spike can be run before all the TK-016 grammars are finished; support for the other languages depends on TK-017 and separate fixtures.

A provisional guide: 2–5 working days for the spike, then 1–3 weeks for a limited integration with a compatible fixture. Without Build/Test, Run/debug and tool installation; the estimate is refined by the results of the spike and is not automatically part of the earlier 12–22 weeks of alpha. Bazel is not yet implemented or verified.

## Workspace shell: UI/UX

The order of the nearest language slice: TK-014 → TK-015 → TK-016 → TK-017. The TK-015 contract is already designed in TK-014. The root and language policy, fixtures and exit criteria: [12_MIXED_LANGUAGE_SUPPORT.md](12_MIXED_LANGUAGE_SUPPORT.md). Mixed languages extend the scope of M2/M3; a separate estimate is still to come, the earlier 12–22 weeks do not include this work automatically.

The agreed direction and the acceptance criteria are recorded in [11_WORKSPACE_UI_UX.md](11_WORKSPACE_UI_UX.md). The first step is a shell with a top bar, tool strips, a central editor and resizable panels on the left, right and bottom. First we verify the layout, focus and size persistence on simple content, then connect the file tree and tabs to the existing document sessions.

Search, Problems, terminal and build are connected as the services become ready. Split editor and chat remain separate later stages. This design does not change the priority of checking compatibility with Xcode and does not mean that all the tools shown are already implemented.

## Target file structure

This is the target structure of the production project; the initial files already exist in Packages/IDE and Apps/SwiftIDE.

```text
Apps/SwiftIDE/
  Composition/AppCompositionRoot.swift
  Composition/WorkspaceScope.swift
  Windows/WorkspaceWindowController.swift
Packages/IDE/Sources/
  IDEDomain/
    Documents/DocumentID.swift
    Documents/DocumentSnapshot.swift
    Documents/DocumentEdit.swift
    Documents/DocumentChangeSet.swift
    Documents/FileRevision.swift
    Build/BuildRequest.swift
  IDEApplication/
    Documents/DocumentEditingBackend.swift
    Documents/DocumentSession.swift
    Documents/DocumentRegistry.swift
    Documents/SaveCoordinator.swift
    Documents/DocumentChangeSubscriptions.swift
    Ports/DocumentFileStore.swift
    Ports/LanguageService.swift
    Ports/RecoveryStore.swift
    UseCases/OpenDocumentUseCase.swift
    UseCases/SaveDocumentUseCase.swift
    UseCases/FormatDocumentUseCase.swift
  EditorPlatformTextKit/
    TextKitDocumentBackend.swift
    NativeEditingBridge.swift
    NativeUndoCoordinator.swift
    TextKitEditorFactory.swift
    TextKitCompatibilityMonitor.swift
  EditorUI/
    EditorHostView.swift
    EditorController.swift
    LineNumberGutterView.swift
    CompletionPresenter.swift
    DiagnosticDecorationRenderer.swift
  WorkspaceUI/
    WorkspaceViewModel.swift
    CommandPaletteViewModel.swift
    ProblemsViewModel.swift
  FileSystemInfrastructure/
    AtomicDocumentFileStore.swift
    FileWatcher.swift
    RecoveryJournal.swift
  LanguageInfrastructure/
    JSONRPCTransport.swift
    OrderedDocumentSync.swift
    SourceKitLanguageService.swift
    LSPPositionMapper.swift
  ProcessInfrastructure/ProcessLauncher.swift
  XcodeInfrastructure/
    ToolchainDiscovery.swift
    XcodeProjectDiscovery.swift
    BSPConfigurationAdapter.swift
  BuildInfrastructure/
    XcodeBuildExecutor.swift
    SwiftPMBuildExecutor.swift
    SimulatorLauncher.swift
  GitInfrastructure/GitClient.swift
Tools/Benchmarks/TextKitBenchmarks/
Fixtures/
```

A custom EditorCore/layout/rendering is created by a separate decision after measurements. Do not start them in parallel automatically: supporting two implementations takes resources away from product features.

## M0: real checks

Fixtures: SwiftPM, a simple macOS app, an iOS simulator app, a multi-target workspace, local packages, generated sources. Record the macOS/Xcode/Swift/BSP versions and the commit of the candidate.

Check semantic features before/after a build, a change of configuration, a server restart and paths with spaces. TextKit separately: plain text mode, long lines, syntax attributes, native undo, CJK/dead keys, absence of a fallback. The README's dependencies do not replace integration results.

Deliverables: CompatibilityMatrix.md, benchmark data, fixtures and an ADR. If BSP is unfit for the target projects, change the Xcode support promise before extending the MVP.

## A separate backlog: Claude chat/agent

The [CLI/SDK integration plan](09_CLAUDE_AGENT_INTEGRATION.md) is recorded: a fake provider and offline tests → a read-only CLI chat with streaming/cancel → an auth/distribution spike → an SDK helper and document-aware tools if needed. It is not included in the M0–M4 estimate; implementation of the integration has not started.

## How to develop a feature

One user scenario → the state owner → port/contract → application behaviour → adapter → UI states → edge cases/measurements. Check cancellation, stale results and the close lifecycle. DI chooses the backend once when the session is created; replacing a live backend is a separate migration feature.
