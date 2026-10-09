# SwiftIDE

A native Swift IDE for macOS, starting with an AppKit editor built on TextKit 2.

SwiftIDE uses Clean Architecture and constructor dependency injection to keep document workflows independent of the editor platform. The current focus is a reliable native editor, followed by file management, language services, and build integration.

**Status: early prototype.** The app opens a sample document in an editable window. Native edits now update `DocumentSession` revisions and events through an input, undo, and IME bridge. Real IME behavior still needs manual acceptance testing, and the app cannot open or save files. It is not ready for editing work you need to keep.

## Requirements

- macOS 15 or later.
- A Swift 6 toolchain with the macOS SDK, provided by Xcode or Command Line Tools.

The package manifests declare Swift tools 6.0 and Swift 6 language mode. Validation so far was done with Swift 6.4; compatibility with earlier compilers has not been established for the full app. There are no external package dependencies.

## Run

From the repository root:

```sh
swift run --package-path Apps/SwiftIDE SwiftIDE
```

The app displays an `Untitled.swift` window containing sample code. The editor uses a monospaced font, plain text configuration, and a shared TextKit 2 storage graph. A compatibility monitor reports an unexpected fallback to TextKit 1.

## Test

```sh
swift test --package-path Packages/IDE
```

The tests cover edit validation, UTF-16 boundaries, versioning, immutable snapshots, change subscriptions, save races through an in-memory store, and the TextKit editor factory. Native-view tests exercise typing, undo/redo, group ownership, composition, and save coordination. Real CJK input, dead keys, and interactive IME behavior still need manual coverage.

## Implemented

- A SwiftPM app shell with a native window, editor host, and basic menus.
- A TextKit 2 backend and an `NSTextView` sharing the same storage graph.
- A document session with versioned native and programmatic edits, UTF-16 validation, change events, and immutable snapshots.
- A shared document undo history and an IME composition bridge.
- An asynchronous save use case with composition-aware coordination and version-aware acknowledgement, backed by an in-memory test store.
- Headless test adapters and native editor regression tests.

## Next steps

**TK-005: the native input, undo, and IME transaction bridge** is implemented and covered by automated tests. Manual acceptance testing with real input methods remains before closing the milestone; real file open/save is the next implementation step.

Real file open/save, recovery, syntax presentation, SourceKit-LSP, and Xcode/build integration are planned. Multi-cursor editing and split views are deferred. A custom text engine is an option only if measurements justify replacing TextKit.

See the [development plan](docs/05_DEVELOPMENT_PLAN.md), [TextKit implementation plan](docs/08_TEXTKIT_IMPLEMENTATION_PLAN.md), and [changelog](CHANGELOG.md).

## Architecture

```text
DocumentSession → DocumentEditingBackend → TextKitDocumentBackend
                                         → StringDocumentBackend (tests)
```

The backend owns mutable text. `DocumentSession` owns revisions, the saved-version marker, and subscriptions, and retains the last committed text paired with its version. Native changes are reconciled through the bridge without applying them to storage a second time. Background consumers receive independent snapshots; Domain and Application do not import AppKit.

Current planning and snapshot operations copy text and have O(n) costs. Large-file support has not been validated.

| Path | Purpose |
| --- | --- |
| `Apps/SwiftIDE` | Executable app, composition root, windows, and menus |
| `Packages/IDE` | Domain, Application, TextKit platform adapter, editor UI, and test support |
| `docs` | Design documents, decisions, quality criteria, and roadmap |

`IDETestSupport` is not linked into the app.

## Documentation

The detailed design documents are currently written in Russian.

- [Product scope and priorities](docs/01_PRODUCT_AND_IMPROVEMENTS.md)
- [Clean Architecture](docs/02_CLEAN_ARCHITECTURE.md)
- [Dependency injection and lifetimes](docs/03_DEPENDENCY_INJECTION.md)
- [Transactions and workflows](docs/04_ENGINE_AND_WORKFLOWS.md)
- [Development plan](docs/05_DEVELOPMENT_PLAN.md)
- [Quality checks and risks](docs/06_QUALITY_AND_RISKS.md)
- [Architecture decisions](docs/07_ARCHITECTURE_DECISIONS.md)
- [TextKit implementation plan](docs/08_TEXTKIT_IMPLEMENTATION_PLAN.md)
- [Claude chat and agent integration plan](docs/09_CLAUDE_AGENT_INTEGRATION.md) — design only; integration is not implemented.
- [Original custom-engine concept](Swift_IDE_Architecture_and_MVP.md) — historical reference, superseded by the current TextKit MVP plan.
