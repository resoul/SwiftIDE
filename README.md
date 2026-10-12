# SwiftIDE

A native Swift IDE for macOS, starting with an AppKit editor built on TextKit 2.

SwiftIDE uses Clean Architecture and constructor dependency injection to keep document workflows independent of the editor platform. The current focus is a reliable native editor, followed by file management, language services, and build integration.

**Status: early prototype.** The app opens UTF-8 text files (or a scratch window with sample code) in an editable window and saves them back. Native edits update `DocumentSession` revisions and events through an input, undo, and IME bridge, and saving refuses to overwrite a file that changed on disk. Real IME behavior and the open, save, conflict, and quit dialogs still need manual acceptance testing, while file watching and crash recovery are implemented and covered by automated tests. Do not rely on it for work you cannot lose.

## Requirements

- macOS 15 or later.
- A Swift 6 toolchain with the macOS SDK, provided by Xcode or Command Line Tools.

The package manifests declare Swift tools 6.0 and Swift 6 language mode. Validation so far was done with Swift 6.4; compatibility with earlier compilers has not been established for the full app. The IDE package pins tree-sitter and language grammar dependencies in its manifest.

## Run

From the repository root:

```sh
swift run --package-path Apps/SwiftIDE SwiftIDE
```

The app starts in Welcome with searchable recent projects and Open Folder. Successful folder openings are saved in app settings; the context menu can pin, locate or remove an entry without deleting its folder. The project menu in the workspace top bar lists open/recent projects and focuses an existing window. Closing the last project/document returns to Welcome; Window → Welcome or reopening from the Dock brings it back after it was closed. Crash recovery still offers unsaved work at startup.

File → New explicitly creates an untitled scratch document with sample code (a central tab when a project is active). File → Save (⌘S) on it, or File → Save As… (⇧⌘S) on any document, asks for a name and moves the document to that file; the original file is left as it was. Use File → Open… (⌘O) to edit a standalone existing file and File → Save (⌘S) to write it. Only UTF-8 and UTF-8 with BOM are supported: binary files, invalid UTF-8, UTF-16 and files over 100 MB are refused rather than altered. If the file changed on disk since it was opened, saving stops and asks whether to overwrite, reload, or cancel. Closing a window or quitting with unsaved changes asks first.

File → Open Folder… opens the shared workspace shell with tool rails, a top bar, status bar and real Files tree. Double-click or Return opens a text file in a tab inside the central editor content of one project window; switching preserves its editor state and Undo. Closing the last tab leaves the project open with empty editor content, and File → Close Project checks all unsaved documents. The Files context menu offers Reveal in Finder, persistent Exclude/Include and Show Excluded. SwiftPM `.build` folders are excluded and orange by default when their package parent is expanded. Focus Editor and Reset Layout work in project windows. Focus Editor hides surrounding panels and chrome while keeping file tabs, and View → Toggle Full Screen (⌃⌘F) uses the same window. Panel providers can supply arbitrary tool views; visibility and preferred dimensions belong to the project and saved by canonical project root. The top/status bars reflect the current document and language-service state. Unconnected tools are disabled; real Git status/ignore integration comes in TK-027. Live acceptance is still pending.

The editor uses a monospaced font, plain text configuration, and a shared TextKit 2 storage graph. A compatibility monitor reports an unexpected fallback to TextKit 1.

To explore the separate workspace layout prototype, choose **Window → Workspace Preview**, or launch it directly:

```sh
swift run --package-path Apps/SwiftIDE SwiftIDE --workspace-preview
```

The preview has resizable side and bottom panels, tool switches, Focus Editor, Reset Layout, and light/dark appearance commands in View. It uses sample data and an editor placeholder; the terminal and assistant do not execute commands or send messages. It now hosts the same WorkspaceUI shell as real project windows, with sample providers for all zones. Its sample layout is saved independently of each real project. Direct preview startup skips recovery prompts; normal startup keeps the existing document workflow.

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
- Real lazy Files trees (TK-026) and content-owned document tabs with local drag reordering (TK-031), with the existing save/close/Undo workflow, independent dirty indicators and persisted project exclusions. Git status remains explicitly unavailable.
- A common workspace shell for Preview and real project Files/editor providers (TK-030), with tool rails, top/status bars, project-scoped shared layout and disabled unavailable tools.
- A reusable WorkspaceUI library for Files/tab presentation, the project configuration sheet and status presentation. App supplies the owning project window; closing it or cancelling a request stores no permission decision. Post-extraction manual acceptance remains pending.
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

Swift completion, hover, jump to definition and diagnostics are connected to the editor window (with a status line and a request timeout), and the C family has completion, hover, definition and diagnostics in a built SwiftPM package; live acceptance and Xcode/build integration remain planned. The document language is chosen in one place (Edit ▸ Language), and C, C++ and Objective-C have syntax colours; Objective-C++ has none. The next language stages are language services verified on mixed-project fixtures and the shared project context. Language services for the other languages are not implemented yet; see the [mixed-language plan](docs/12_MIXED_LANGUAGE_SUPPORT.md). Bazel is an accepted direction: shared project context, a SourceKit-LSP/BSP spike, language services for a configured workspace, then setup and Build/Test; see the [Bazel plan](docs/13_BAZEL_SUPPORT.md). Bazel integration is not implemented or verified. Multi-cursor editing and split views are deferred. A custom text engine is an option only if measurements justify replacing TextKit.

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
- [Workspace UI and UX](docs/11_WORKSPACE_UI_UX.md) — target layout, implemented Welcome/Files/common shell, panel behavior and acceptance.
- [Mixed-language support](docs/12_MIXED_LANGUAGE_SUPPORT.md) — accepted direction for C, C++, Objective-C and Objective-C++ within Swift projects; language selection, highlighting, build context and staged acceptance; not implemented yet.
- [Bazel support](docs/13_BAZEL_SUPPORT.md) — accepted direction, shared project context, BSP/toolchain requirements, phased implementation and acceptance; not implemented or verified.
- [Code style and linting](docs/14_CODE_STYLE_AND_LINTING.md) — TK-023: pinned SwiftFormat and SwiftLint, a SwiftSyntax blank-line checker, local commands and a CI workflow; the workflow has passed on the `xcode-27` runner image.
- [Workspace components and Git](docs/15_WORKSPACE_AND_GIT.md) — implemented Welcome/Files/tabs/common shell; implemented Git inspection/local actions and implemented Clone/Fetch/Push/fast-forward Pull, file/folder colours and exclusions.
- [Third-party software notices](THIRD_PARTY_NOTICES.md)
- [Original custom-engine concept](Swift_IDE_Architecture_and_MVP.md) — historical reference, superseded by the current TextKit MVP plan.

Git inspection is available in real project windows: **View → Source Control** (⌘3), **Git Log** and **Refresh Git**, plus the top-bar branch reference picker. Changes distinguish disk and index; selection opens a central read-only Diff tab while original editors retain their unsaved text and Undo. The branch picker offers View history plus the local actions described below; Clone/Fetch are available in the first TK-029 slice; Push is available with explicit review; Fast-forward Pull is available; merge/rebase remain later work. See [the Git contract](docs/15_WORKSPACE_AND_GIT.md#tk-027-implementation-adr-040).

Git local actions (TK-028): Source Control offers Stage file / Unstage for whole files and Commit… for ALL staged contents. Git → Commit Staged… (⌘K) opens its multiline message form; errors/cancellation retain the draft. The branch picker creates at HEAD without switching, or explicitly switches a local branch after save-or-cancel checks across every open document in the worktree. Actions show bounded live output and Cancel. Clone/Fetch are available in TK-029; Push is available; Fast-forward Pull is available; live acceptance remains pending.


Clone/Fetch (TK-029 first slice): **Welcome → Clone Repository…** or **Git → Clone Repository…** asks for source, parent folder and a new folder name. Existing destinations are refused; failure/cancel may leave a partial folder for inspection. Only verified success opens/adds the project. **Git → Fetch…** opens the branch picker: choose a remote and Fetch. Its output and Cancel appear in Source Control; local HEAD, staged/working files and unsaved editors remain unchanged. Uses configured Git credential helpers and OpenSSH keys/agent in batch mode; custom SSH wrappers/app login UI are not included. SSH/HTTPS live acceptance is pending. See [the network contract](docs/15_WORKSPACE_AND_GIT.md#tk-029-first-slice-clone-and-fetch-adr-042).


Push (TK-029 second slice): **Git → Push…** or the branch picker's **Push…** opens a project sheet. Choose a local branch, remote and destination, then **Review Destination** to see the exact commit and push address. Only **Push** sends it. Non-fast-forward/policy/auth failure stops with output; force, tags, mirror and automatic upstream are excluded. Dirty editors and Undo stay intact. Actual SSH/HTTPS/signing and live acceptance remain pending; cancellation may leave remote acceptance uncertain. See [the Push contract](docs/15_WORKSPACE_AND_GIT.md#tk-029-second-slice-reviewed-push-adr-043).


Pull (TK-029 third slice): **Git → Pull…** or branch-picker **Pull…** reviews one fetch source and the current local branch. **Pull** saves or cancels open worktree documents, fetches one branch and updates only by fast-forward. Tracked/index changes and divergence stop with an error; nothing is automatically stashed/discarded/merged/rebased. Editor reloads retain Undo. Failure/cancellation may leave fetched refs or completed checkout changes. See [the Pull contract](docs/15_WORKSPACE_AND_GIT.md#tk-029-third-slice-fast-forward-pull-adr-044).


Conflict resolution (TK-033): **Source Control → Resolve conflict…** or double-click an unmerged path. Base/Ours/Theirs appear above the original native result editor; choosing text is undoable and does not stage. **Save and mark resolved** stages only the checked saved/filtered result. Missing/binary results have a central tool tab; restore/delete require confirmation, and restoring is separate from marking. Unsupported types/limits require external Git.

Local integration (TK-034): **Git → Merge… / Rebase…** reviews locally known targets without Fetch. Merge stops before commit; resolve then Continue with a message. Linear rebase rewrites the current branch and stops for conflicts/empty replay; Continue/confirmed Skip/Abort are in Source Control and Git menu. Editors participate in Save/Cancel and retain Undo. Pull remains fast-forward-only. See [the contract](docs/16_GIT_CONFLICTS_AND_INTEGRATION.md); live acceptance remains pending.
