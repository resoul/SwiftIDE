# SwiftIDE

A native Swift IDE for macOS, starting with an AppKit editor built on TextKit 2.

SwiftIDE uses Clean Architecture and constructor dependency injection to keep document workflows independent of the editor platform. The current focus is a reliable native editor, followed by file management, language services, and build integration.

**Status: early prototype.** The app opens UTF-8 text files (or a scratch window with sample code) in an editable window and saves them back. Native edits update `DocumentSession` revisions and events through an input, undo, and IME bridge, and saving refuses to overwrite a file that changed on disk. Real IME behavior and the open, save, conflict, and quit dialogs still need manual acceptance testing, and there is no file watching or crash recovery yet. Do not rely on it for work you cannot lose.

## Requirements

- macOS 15 or later.
- A Swift 6 toolchain with the macOS SDK, provided by Xcode or Command Line Tools.

The package manifests declare Swift tools 6.0 and Swift 6 language mode. Validation so far was done with Swift 6.4; compatibility with earlier compilers has not been established for the full app. There are no external package dependencies.

## Run

From the repository root:

```sh
swift run --package-path Apps/SwiftIDE SwiftIDE
```

The app starts with an untitled scratch window containing sample code. File → Save (⌘S) on it, or File → Save As… (⇧⌘S) on any document, asks for a name and moves the document to that file; the original file is left as it was. Use File → Open… (⌘O) to edit an existing file and File → Save (⌘S) to write it. Only UTF-8 and UTF-8 with BOM are supported: binary files, invalid UTF-8, UTF-16 and files over 100 MB are refused rather than altered. If the file changed on disk since it was opened, saving stops and asks whether to overwrite, reload, or cancel. Closing a window or quitting with unsaved changes asks first.

The editor uses a monospaced font, plain text configuration, and a shared TextKit 2 storage graph. A compatibility monitor reports an unexpected fallback to TextKit 1.

To explore the separate workspace layout prototype, choose **Window → Workspace Preview**, or launch it directly:

```sh
swift run --package-path Apps/SwiftIDE SwiftIDE --workspace-preview
```

The preview has resizable side and bottom panels, tool switches, Focus Editor, Reset Layout, and light/dark appearance commands in View. It uses sample data and an editor placeholder; the terminal and assistant do not execute commands or send messages. Its layout is saved as one preview layout, independently of document windows. Direct preview startup skips recovery prompts; normal startup keeps the existing document workflow.

## Test

```sh
swift test --package-path Packages/IDE
swift test --package-path Apps/SwiftIDE
```

Code style and linting (TK-023) run from the repository, with SwiftFormat and SwiftLint pinned and downloaded into `Tools/Lint/.tools` on first use (SHA-256 checked), and a SwiftSyntax checker for the blank-line rules that is built with SwiftPM:

```sh
Tools/Lint/lint.sh        # checks everything, changes nothing; exit 1 on a violation
Tools/Lint/format.sh      # rewrites the code to the agreed style; commit its result on its own
Tools/Lint/selftest.sh    # the tools against each other on small fixtures
swift test --package-path Tools/Lint
```

The tests cover edit validation, UTF-16 boundaries, versioning, immutable snapshots, change subscriptions, save races, disk revisions, the file store on real temporary files (BOM, malformed UTF-8, symlinks, permissions, external changes), and the TextKit editor factory. Native-view tests exercise typing, undo/redo, group ownership, composition, and save coordination. Real CJK input, dead keys, and interactive IME behavior still need manual coverage.

## Implemented

- A SwiftPM app shell with a native window, editor host, and basic menus.
- A TextKit 2 backend and an `NSTextView` sharing the same storage graph.
- A document session with versioned native and programmatic edits, UTF-16 validation, change events, and immutable snapshots.
- A shared document undo history and an IME composition bridge.
- Watching the file of an open document: another program's change reloads a clean document, warns about one with unsaved changes, and a deleted file is reported.
- Recovery of unsaved text after an unclean end: the next start offers it back per document, and a file that changed meanwhile still conflicts on Save.
- File open and save for UTF-8 text: strict reading, atomic replacement that keeps permissions, ACLs, and extended attributes, conflict detection by file content, and an open-document registry that treats hard links as one document.
- One unsaved-changes procedure for closing a window and for quitting, tied to the text version the user decided about.
- An asynchronous save use case with composition-aware coordination and version-aware acknowledgement.
- A line-number margin driven by an incrementally maintained line index.
- Syntax colours for Swift files: tree-sitter in the background, drawn as TextKit 2 rendering attributes, so colouring never touches the document, its revisions or its undo history. Large files and very long lines are shown plain.
- Headless test adapters and native editor regression tests.

## Next steps

**TK-005: the native input, undo, and IME transaction bridge** is implemented and covered by automated tests. Manual acceptance testing with real input methods remains before closing the milestone; **TK-006: real file open/save with a disk revision policy** is implemented as well.

Swift completion is connected to the editor window, with a status line and a request timeout; live acceptance, diagnostic presentation and Xcode/build integration remain planned. The document language is chosen in one place (Edit ▸ Language), and C, C++ and Objective-C have syntax colours; Objective-C++ has none. The next language stages are language services verified on mixed-project fixtures and the shared project context. Language services for the other languages are not implemented yet; see the [mixed-language plan](docs/12_MIXED_LANGUAGE_SUPPORT.md). Bazel is an accepted direction: shared project context, a SourceKit-LSP/BSP spike, language services for a configured workspace, then setup and Build/Test; see the [Bazel plan](docs/13_BAZEL_SUPPORT.md). Bazel integration is not implemented or verified. Multi-cursor editing and split views are deferred. A custom text engine is an option only if measurements justify replacing TextKit.

See the [development plan](docs/05_DEVELOPMENT_PLAN.md), [TextKit implementation plan](docs/08_TEXTKIT_IMPLEMENTATION_PLAN.md), and [changelog](CHANGELOG.md).

## Architecture

```text
DocumentSession → DocumentEditingBackend → TextKitDocumentBackend
                                         → StringDocumentBackend (tests)
Open/Save/Reload use cases → DocumentFileStore → AtomicDocumentFileStore
                                               → MemoryDocumentFileStore (tests)
```

The backend owns mutable text. `DocumentSession` owns revisions, the saved-version marker, and subscriptions; it keeps no copy of the text. Each edit, native or programmatic, costs time proportional to the edit, not to the file; only a snapshot copies the document. Native changes are described from the storage's own edited range and accounted for without applying them to storage a second time. Background consumers receive independent snapshots; Domain and Application do not import AppKit.

Current planning and snapshot operations copy text and have O(n) costs. Large-file support has not been validated.

| Path | Purpose |
| --- | --- |
| `Apps/SwiftIDE` | Executable app, composition root, windows, and menus |
| `Packages/IDE` | Domain, Application, file system and TextKit adapters (`FileSystemInfrastructure`, `EditorPlatformTextKit`), editor UI, and test support |
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
- [Manual acceptance checklist](docs/10_MANUAL_ACCEPTANCE.md) — what automated tests cannot check: live window, IME, dark mode, large pastes.
- [Workspace UI and UX](docs/11_WORKSPACE_UI_UX.md) — agreed target layout, panel behavior, visual principles, and implementation stages; design only.
- [Mixed-language support](docs/12_MIXED_LANGUAGE_SUPPORT.md) — accepted direction for C, C++, Objective-C and Objective-C++ within Swift projects; language selection, highlighting, build context and staged acceptance; not implemented yet.
- [Bazel support](docs/13_BAZEL_SUPPORT.md) — accepted direction, shared project context, BSP/toolchain requirements, phased implementation and acceptance; not implemented or verified.
- [Code style and linting](docs/14_CODE_STYLE_AND_LINTING.md) — TK-023: pinned SwiftFormat and SwiftLint, a SwiftSyntax blank-line checker, local commands and a CI workflow; the workflow has not run on a runner yet.
- [Third-party software notices](THIRD_PARTY_NOTICES.md)
- [Original custom-engine concept](Swift_IDE_Architecture_and_MVP.md) — historical reference, superseded by the current TextKit MVP plan.
