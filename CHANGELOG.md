# Changelog

Changes to the current SwiftIDE prototype are recorded here. Earlier repository history is not reconstructed in this file.

## Unreleased

### Planned (reusable workspace UI)

- Accepted ADR-030 and TK-024: a `WorkspaceUI` target in `Packages/IDE` for the project configuration dialog and project status presentation, explicit parent-window injection and package-owned UI tests. App retains composition, main-menu wiring and window lifecycle. The extraction is not implemented; this entry records the documentation decision only.

### Planned (workspace and Git)

- Accepted ADR-031 and TK-025–TK-029: Welcome/project switching, real Files/tabs, Git Changes/diff/branches/history, then local actions and network workflows. Recorded red untracked files, green index additions, blue changes and orange excluded/ignored files and folders, with distinct reasons, badges and folder aggregation. Added docs/15 and future manual acceptance section R. No implementation or Git action was performed for this documentation change.

### Added

- TK-018, third slice (ADR-031): the window subtitle names the target of a SwiftPM file ("Target: App"), learnt from `swift package describe` run in the background (bounded in time and output, offline, writing nothing into the project) once per package and again when its `Package.swift` is saved; a file not yet listed belongs to the target whose folder holds it. No chooser yet: SwiftPM never gives a file two targets. Not yet seen in a live window.

- TK-018, second slice (ADR-030): File ▸ Open Folder… makes a folder the project of every file inside it, over the nearest package (nested packages do not change the workspace), and File ▸ Close Opened Folders undoes it; documents move to the server of their new project at once. The context is now a value (root, build system, explicit or found, revision). A folder is called one of fallback settings only when no project lies a few levels below it, because the server finds a package there (measured). The subtitle warns that C-family flags may be missing for a file in the system temporary folders. Not yet seen in a live window; the target choice and the "prepare language features" command are still to come.

- TK-018, first slice (ADR-029): the language server's readiness is kept as independent groups (server, settings, background work, trust) and its `$/progress` is read, several operations at once; the window subtitle names the one most useful reason ("Preparing package · 2 / 5", "Using fallback settings", "Project configuration disabled"). Diagnostics made while the package is first prepared are withheld and a fresh report is pulled when that ends; those on fallback settings are paler and say so. SourceKit-LSP's question whether to trust the project's configuration is asked of the user once per project (default "Don't allow"), the decision is kept and can be changed from the new Project menu. Not yet seen in a live window; File ▸ Open Folder, the explicit root and the target choice are still to come.

- ADR-028 records measured facts about SourceKit-LSP of Xcode 27.0 for the shared project context (TK-018): background preparation modes, the workspace trust prompt for `.sourcekit-lsp/` and `.bsp/`, behaviour on fallback settings and `compile_flags.txt`; `Tools/CompatibilityMatrix/prepare_probe.py` reproduces the observations. The lint workflow now uses `actions/checkout@v7` and `actions/cache@v6` (Node 24). No code changed.

- The design documents in `docs/` and `Swift_IDE_Architecture_and_MVP.md` are translated from Russian into English; links between them (including the section anchors of the architecture decisions) are updated.

- Added the TK-023 implementation task for pinned SwiftFormat/SwiftLint, parameter layout, guard/return/if spacing checks and CI. Initial mass formatting is planned as a separate commit; tooling is not connected yet.

- Documented Bazel support in ADR-023 and TK-018–TK-022: shared project context, SourceKit-LSP/BSP spike, language services for configured workspaces, then setup and Build/Test. Added toolchain requirements, provisional estimates, risks, compatibility and manual acceptance plans; integration is not implemented or verified.

- Documented mixed Swift/C/C++/Objective-C/Objective-C++ support in ADR-021 and TK-014–TK-017: Swift completion UI, shared document language selection, local highlighting, then language services with verified build settings. Added fixture, risk and manual acceptance plans; additional languages are not implemented yet.

- Documented the target workspace UI/UX: central editor, tool rails, resizable side and bottom panels, focus handling, layout persistence, and staged implementation.
- A separate Workspace Preview window (Window menu or `--workspace-preview`) with native split panes, sample tools, an editor placeholder, layout persistence, Focus Editor, Reset Layout, and appearance preview commands. Real document windows retain their existing workflow. Three app tests cover panel switching, layout serialization, and restoring resized panes after Focus Editor.
- A macOS SwiftPM application with a native editor window, sample Swift document, and basic application, file, and edit menus.
- A TextKit 2 editor factory and host sharing the document backend's storage graph, with plain text configuration and fallback monitoring.
- Domain and Application modules for document IDs, immutable snapshots, UTF-16 edit batches, revision tracking, and change subscriptions.
- Validation for stale revisions, invalid ranges, surrogate boundaries, overlapping edits, and byte-identical no-ops.
- A save use case with version-aware acknowledgement and an in-memory file store for tests.
- Headless document adapters, backend/application tests, and TextKit editor factory tests.
- A native editing bridge that reconciles committed TextKit changes with document revisions and publishes one change event per text-changing transaction without writing the edit back to storage.
- A document-scoped undo manager shared by native typing and programmatic edits, with explicit ownership of undo groups and undo/redo origins.
- IME composition revisions and lifecycle events, including coalescing of internal storage changes within native input operations.
- Composition-aware save coordination: explicit saves request composition completion, while autosave waits without interrupting input.
- Native editor regression tests for undo grouping, composition, preflight rejection, and save coordination, plus seeded inverse-edit round-trip tests.
- Real file open and save (TK-006): File → Open… (⌘O) and Save (⌘S) for UTF-8 and UTF-8 BOM text files, window title and edited marker, and a prompt when closing with unsaved changes.
- `AtomicDocumentFileStore`: strict UTF-8 reading with a size limit (binary, malformed UTF-8 and UTF-16 are refused, never repaired), and saving through a same-directory temporary file and atomic `rename` inside an `NSFileCoordinator` write. Permissions, ACLs and extended attributes are carried over; a symlink is written through, never replaced.
- Disk revisions (`FileRevision`: file identity, size, nanosecond mtime, SHA-256). A save is judged against the revision the text was based on by re-reading the file and comparing its bytes, never its metadata; a changed file is a conflict and nothing is written, while a file that was only touched or rewritten with identical bytes is not.
- Conflict handling: the user chooses Overwrite, Reload from Disk (an ordinary undoable edit) or Cancel.
- `DocumentRegistry` and `OpenDocumentUseCase`: one session per file (canonical path and file identity, so hard links open once), concurrent opens of one file coalesce, a cancelled open leaves nothing behind.
- Save As (⇧⌘S) and a nameable scratch window: ⌘S on the untitled window asks for a name, the document then becomes that file (registered, with its disk revision); the name must be free or explicitly replaced, a file open in another window is refused, and the close prompt can save an untitled document. See ADR-013.
- `UnsavedChangesCoordinator`: one procedure for closing a window and for quitting, so ⌘Q no longer skips the save prompt, and a window stays open when text was typed while its save was running.
- Architecture documents, a development roadmap, quality criteria, and plans for language/agent integrations.

### Fixed

- Undo of adjacent deletions by normalizing touching inverse edits into an applicable batch.
- Typing and programmatic edits merging into one undo step within the same event; caller-owned groups remain intact, and the bridge does not open groups during preflight.
- Pending autosave blocking explicit Save during composition. Explicit requests now join and promote the waiting operation, and retry if its originating task is cancelled.

### Measured

- TK-008 benchmark tool (`Tools/Benchmarks/TextKitBenchmarks`) and results ([docs/benchmarks/TK-008-results.md](docs/benchmarks/TK-008-results.md)): opening 100 MB takes 0.8 s and viewport work stays near 4 ms at any size, but each keystroke costs time proportional to the file (about 20 ms per MB) because the pipeline copies and compares the whole text; a single very long line makes TextKit itself slow (about 1.3 ms per KB of line). Follow-up designed in ADR-012 (TK-011).

### Changed

- Workspace Preview now separates the editor and side/bottom panels with theme-aware backgrounds, 10-point rounded corners, subtle borders, and small gutters. Text and scroll views use transparent backgrounds so each panel reads as one surface.
- Editing now costs time proportional to the edit, not to the file (ADR-012, TK-011). `DocumentSession` keeps no copy of the text; edits are validated and described against the backend's storage (`TextSource`), native edits are described from the storage's edited range, and the whole text is copied only for a snapshot (save, reload). Typing in a 100 MB file went from 1.3-1.9 s to about 5 ms per keystroke, programmatic edits from 3.5 s to 0.3 ms, undo from 2.7 s to 4 ms, peak memory from 1.5 GB to 0.8 GB. Saving large files is slower because the copy moved there (170 ms to 424 ms at 100 MB). See [docs/benchmarks/TK-011-results.md](docs/benchmarks/TK-011-results.md).
- `DocumentEditingBackend` now provides `TextSource` access and an `editGeneration` counter; `PreparedDocumentEdit` describes what it replaces instead of carrying whole texts; `NativeEditCommit` carries a `NativeTextEffect` instead of a list of edits.
- `DocumentFileStore` now reads files and writes against an expected disk revision, returning the new revision. The in-memory store applies the same revision rules.

### Fixed (review of TK-006)

- A save no longer overwrites external changes that kept the same inode, size and modification time: the file content is checked before every replacement.
- Saving aborts before touching the original when permissions, owner, ACLs or extended attributes cannot be carried over (`cannotPreserveMetadata`), instead of continuing silently.
- Save-and-close and Overwrite no longer close the window over edits made while the write was in progress.
- Quit no longer lets through documents that changed while another document's question was open: answers are tied to the text version they were given for, and the list of windows is read again after every answer.

### Added (TK-007a)

- Line numbers in the editor margin (`LineNumberRulerView`, an `NSRulerView`). Numbers come from `LineIndex`, which is kept up to date from published change sets, so they are right for lines that were never laid out; only the rows in view are visited (about 0.07 ms), a wrapped line is numbered once, and the empty last line after a final newline is numbered. Lines end with `\n`, `\r\n` or `\r`. See ADR-014 and [docs/benchmarks/TK-007a-results.md](docs/benchmarks/TK-007a-results.md).
- `LineIndex`: chunked line lengths with the terminator kept per line, edit cost O(edit + chunks), joins and splits of `\r\n` followed without reading text; `DocumentLineIndex` follows a session and rebuilds from the backend when it cannot. Property tests against a rescan, including edits across chunk boundaries.

### Added (ordered sync with SourceKit-LSP)

- New module `LanguageInfrastructure`: a JSON-RPC connection with one ordered outbox (a request made after an edit reaches the server after it), document sync that sends edits as ranges, falls back to one full-text `didChange` when it falls behind, and starts a fresh server with every open document after a crash; completion that drops answers for text, caret or server that are no longer current (and never runs over marked text); diagnostics that are called current only when the server names the version. SourceKit-LSP of Xcode 27.0 sends no version, so its reports are "unverified" until the next edit and "stale" after it. ADR-020.
- Descriptions, jump to definition and problems in the editor window (TK-017, second slice, ADR-027): resting the pointer on a word (or Control-Shift-Space at the caret) shows the server's description in a small window that takes neither keyboard nor pointer; Command-click or Control-Command-J jumps to the definition (the same document moves the caret, another file opens in its own window at the line; files of the toolchain and the SDK open read-only); problems from the server are drawn as wavy lines under the text, a dot beside the line number and a count in the title bar, move with the text as it is typed and turn pale until the next report, and their text is shown in the description. TextKit 2's rendering attributes do not draw underlines on this system, so an overlay view draws the lines. Edit ▸ Quick Help and Jump to Definition are new. Several definitions are offered in a pop-up menu, Edit ▸ Go Back (Control-Command-Left) returns to where a jump started, and a report that names no version is drawn paler than one that does (and paler still after an edit). Not yet seen in a live window; no code actions.
- A problem that has no extent (the compiler reports "missing argument" between characters) is drawn over the word at that place or, failing that, over the line, and the text of the problems of a line is shown when the pointer rests on the dot in the line-number margin. Syntax colours of types, functions, properties and constants are now four distinct hues in both appearances. The lint workflow runs on the `xcode-27` runner image.
- Completion for C, C++ and Objective-C (TK-017, first slice, ADR-026): documents of those languages are given to SourceKit-LSP under their own `languageId` (it hands them to its clangd), documents with no file get a stand-in name with the right extension, and clangd's marker in front of labels is not shown. Verified on the real server with a new fixture `Fixtures/SwiftPMMixed` (C, C++, Objective-C and Swift targets): C/C++/Objective-C files complete their own symbols and Swift sees the C and Objective-C targets. The package must have been built, and must not be in the system's temporary folder, or clangd has no compile flags; the first answers after opening a file may come without them. No diagnostics, hover or definition yet.
- Code style and linting (TK-023, docs/14): pinned SwiftFormat 0.63.1 and SwiftLint 0.65.1 downloaded into `Tools/Lint/.tools` with a SHA-256 check; `.swiftformat` and `.swiftlint.yml`; `spacing-check`, a SwiftSyntax tool for "blank line before a `return` that follows other statements" and "blank line after a multi-line `if`" (reports `path:line:column`, has a verified `--fix`); `Tools/Lint/lint.sh` (checks only), `format.sh` (explicit rewrite), `selftest.sh`, and a GitHub workflow that has not run on a runner yet. The whole code base was formatted once (105 files, no behaviour change; all tests pass) — commit that on its own.
- Syntax colours for C, C++ and Objective-C (TK-016, ADR-025): pinned Tree-sitter grammars (tree-sitter-c 0.24.2, tree-sitter-cpp 0.23.4, tree-sitter-objc 3.0.2, MIT) with queries generated from the grammars' node types by `Tools/Grammars/generate_queries.py`. An unclosed `/*` colours the rest of the file as comment, as the compiler reads it. Objective-C++ has no colours (no grammar reads Objective-C and C++ mixed without errors), and Apple headers with `NS_OPTIONS`-style macros are read with errors by the Objective-C grammar, so colours there are partial. The subtitle no longer says "no syntax colours" for the three languages.
- One place that says what language a document is (TK-015, ADR-024): Swift, C, C++, Objective-C, Objective-C++ or plain text, decided by the user's choice, then the build context (not connected yet), then the file name (`.h` is taken for C as a guess). Edit ▸ Language chooses a language for a document or goes back to Automatic; the choice does not touch the text, its version, Undo or the file, survives Save As and is remembered by path. The window subtitle shows the language. Syntax colours and the language server follow it: another language restarts or stops the colours and moves the document on or off the server. Only Swift has colours and a server so far.
- Swift completion in the editor window (TK-014, ADR-022): a popup under the caret that never takes focus, opened by typing `.` after a member base or by Control-Space (also Edit ▸ Complete, Esc, F5). Typing narrows the list locally (prefix, then start of a later word of the name); Return or Tab accepts only while the list is showing, as one undoable edit, with the caret inside the parentheses of a call. It closes on a character that does not belong to a word, on any other edit or caret move, and never opens over marked text. One SourceKit-LSP per package root (nearest `Package.swift`) and one for loose files and Untitled; servers stop when their last document closes and on quit. The item's replacement range named by the server is honoured. When there is no list the popup says why in one line (waiting for SourceKit, starting, restarting, not ready, no suggestions, not available, not responding); a request is withdrawn after 5 seconds, and an empty "more to come" answer from a server that is still loading a package is asked again every half second. Not yet checked in a live window or with a real input method; no snippet placeholders or documentation popup.
- An edit that starts or ends between the CR and the LF of one line terminator is sent widened to the whole terminator (the protocol has no position there).

### Added (Xcode / BSP compatibility)

- `Fixtures/` (SwiftPM package, macOS app, iOS-simulator app, workspace of two projects with a local package and a script-generated source) and `Tools/CompatibilityMatrix/` (a Python LSP client, scenario and cost probes, a pbxproj generator). Findings in `docs/11_COMPATIBILITY_MATRIX.md`; ADR-019 (accepted): SwiftPM is the supported scenario, Xcode projects are experimental (Xcode 27.0, after a successful build of the chosen scheme, configuration and destination); the first integration is `xcode-build-server` parsing the IDE's own build logs, shipped inside SwiftIDE with its own Python runtime; `sourcekit-xcode-bsp` stays a research candidate; semantics are marked stale when settings change; user project files are not touched. No application code changed. Third-party build servers are cloned into `Tools/CompatibilityMatrix/vendor/` (git-ignored), not bundled.

### Fixed (review of recovery, watching and capture)

- A large document containing an emoji (or any character outside the BMP) that straddled the boundary between two copied pieces was saved, and kept for recovery, with two replacement characters in its place. The pieces are now joined across a split pair.
- Restoring unsaved text no longer lets Save overwrite another program's change made while the "Restore / Discard" question was on screen: a saved text is always judged against the file revision the recovered text was based on.
- Save As while the old file was being re-read after an outside change crashed the app; the stale read is now dropped (`DocumentError.pathChanged`).
- The recovery copy a restored document came from is removed only after the new copy is confirmed written; a failed or refused write leaves the old copy in place.
- Quit with "Don't Save": removing recovery copies is part of the decision now. Text typed or windows opened while the copies were being removed are asked about, and a refused quit puts the protection back. Previously the app could quit over newer text or leave recovery stopped.

### Changed (Save no longer freezes the window on large files)

- Saving and the recovery checkpoint copy a large document (over 1 000 000 UTF-16 units) in slices of 262 144 units, giving the main thread back between them, and build the final `String` off the main thread; edits made while it is being copied are applied to the copy, and the version, path and disk revision are taken at one instant when the copy is complete and no marked text is live. On a 100 MB file the main thread was held for 306 ms by a save; the longest gap is now 0.1–0.3 ms (the first copy in a fresh process up to 27 ms). `DocumentSession.capture`, `CapturePolicy`, `DocumentCapture`. See ADR-018 and docs/benchmarks/ADR-018-capture.json. Not checked in a live window.

### Added (watching the file)

- When another program changes the file of an open document (ADR-017): a document without unsaved changes is reloaded by itself, as an ordinary edit that can be undone, with a strip above the text ("changed on disk and reloaded", Undo); a document with unsaved changes is left alone and the strip offers Reload or Keep Mine; a file that was deleted or moved gets a strip with Save As. Saving still reports a conflict whatever was chosen. The document's own saves, `touch` and a rewrite with the same bytes are not changes.
- New: `FileWatching` port, `ExternalChangeMonitor`, `VnodeFileWatcher` (kernel events on the file and its directory; re-opens a file that another program replaced by renaming over it), `DocumentFileStore.currentRevision(path:assumingUnchangedFrom:)` (with a default implementation), the general `DelayClock`. One strip above the text now serves external changes, read-only mode and the long-line warning, in that order. Not checked in a live window yet.

### Added (recovery of unsaved text)

- After an unclean end, the next start offers the unsaved text back, one question per document ("Restore" / "Discard"; ADR-016). Unsaved text is written to `~/Library/Application Support/SwiftIDE/Recovery/` two seconds after the last edit (at most ten seconds after the first, however steadily one types), at once when the app goes to the background, and removed when the document is saved, saved under another name, closed without saving or quit with "Don't Save". Documents over 16 MB are not kept, and the window says so.
- Restoring writes nothing to disk: the text becomes an ordinary unsaved edit (undoable). If the file changed on disk since, saving is a conflict as for any outside change. A file that is gone or unreadable, and a document that never had a file, open as Untitled. A copy that is cut short or altered is never offered; it is listed as unreadable.
- New: `RecoveryStore` port, `RecoveryCoordinator`, `RecoveryRestorer`, `RecoveryJournal` (checksummed record files, private to the user, replaced atomically), `DocumentSession.subscribeToSaves`. Not checked in a live window yet.

### Experiment (TK-012, step 2, not shipped)

- `Tools/Experiments/LongLineSplit`: a probe that hands TextKit a long line in pieces by subclassing `NSTextContentStorage`. Typing in a 1 MB line drops from 1533 to 21 ms, but TextKit can fall into an endless layout loop after Enter or Backspace around a split line, so nothing was changed in the editor. Findings, numbers and options: docs/benchmarks/TK-012-step2-prototype.md.

### Added (TK-012, long lines, step 1)

- A very long line (over 16 000 characters) now raises a notice above the text with "Make Read-Only" and "Keep Editing"; the file still opens editable by default. `LineIndex.longestLine` answers in one step per chunk, `LongLineMonitor` watches it after every change (the notice also appears when a long line is pasted and goes when it is shortened), `NoticeBanner` and `EditorContainerView` show it. Editing a long line is not faster yet. See ADR-015 and [docs/benchmarks/TK-012-long-lines.md](docs/benchmarks/TK-012-long-lines.md).
- Measured: turning off line wrapping makes long lines slower, not faster (51 KB: 257 ms per keystroke against 84 ms wrapped).
- `DocumentLineIndex` now has any number of observers (`subscribe`) instead of one `onChange` closure.

### Added (TK-007c)

- Syntax colours for Swift files (ADR-014): tree-sitter parses in the background from the document's own edits (incrementally, from a private chunked copy of the text), the editor draws the result as TextKit 2 rendering attributes. Colours follow edits at once and are replaced by the next result; the document, its revisions and undo are untouched. Files over 5 MB, lines over 1000 characters and lines with over 50 coloured runs are drawn plain (the window says so for large files). See [docs/benchmarks/TK-007c-results.md](docs/benchmarks/TK-007c-results.md).
- New dependencies, pinned exactly: swift-tree-sitter 0.25.0 and tree-sitter-swift 0.7.4. Licences in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
- New module `SyntaxInfrastructure`, the `SyntaxHighlighter` port, `SyntaxCoordinator`, `HighlightState`, `SyntaxPolicy`, `SyntaxPresenter` and `SyntaxTheme`.

### Fixed (second review of TK-007c)

- The 5 MB limit for syntax colours was checked only when a window opened, so pasting a large text into a small Swift file, or reloading a file that had grown, left colouring running without a limit. `SyntaxColouringController` now checks after every change: past the limit it stops the coordinator and the presenter, the highlighter drops its tree and text copy at once (`stop()`), and the colours leave the screen. They come back once the text is 10% under the limit. The oversized edit is never handed to the highlighter (session observers now run in subscription order).
- Save As did not change the language choice (`.txt → .swift` stayed plain, `.swift → .txt` stayed coloured). The window now re-evaluates after Save As and the subtitle follows the state.
- A presenter created for a view that was already laid out never learned what was on screen, and a released presenter left its colours drawn. Both fixed.
- On a 10 MB file, sixty fast keystrokes queued sixty parses and left the colours 2.2 s behind; requests superseded by a newer queued one are now skipped (57 ms). The benchmark's "colour lag" measured until the result was received, not until the picture; it now reports both, plus a burst phase and the highlighter's own statistics. See docs/benchmarks/TK-007c-results.md.
- The test helper that counted coloured pixels created an `NSColor` per pixel (about a second per picture, and a lot of memory); it reads the bitmap bytes now.
- The highlighter test helper waited for answers against the wall clock, so a Mac that slept in the middle of a run failed tests that were fine; it uses a clock that stops during sleep.

### Fixed (review of TK-007c)

- A document that shrank below the text that had been on screen made the syntax coordinator (and the highlighter) build an invalid range and crash; every range is now clamped to the current text.
- After an edit that changes colours far away (adding or removing `/*`), text laid out before the edit kept its old colours when scrolled back to: colours already known were taken as the union of all earlier windows. The known window is now only what the latest answer describes, a window from an older version does not count for a newer one, and scrolling tells the coordinator what is in view (TextKit reuses laid-out text without asking the validator).
- Redrawing colours of text far from the viewport made TextKit lose the last lines of a long document when the view was at its end; redraws are now limited to what is in view and the rest waits until it is scrolled to.
- The highlighter now receives its result handler through the same queue as its other messages.
- A block comment that is never closed now colours the rest of the text as comment, as Swift reads it. The grammar only recognises a closed one, so typing `/*` used to leave the code below coloured until `*/` was typed.

### Measured (TK-007b)

- Colour application prototype ([docs/benchmarks/TK-007b-results.md](docs/benchmarks/TK-007b-results.md)): TextKit 2 rendering attributes, applied by a validator per laid-out fragment, colour text without touching the document, its revisions or undo, follow edits, and cost about 2.5 ms per keystroke at any file size up to 100 MB (against about 1.5 ms for attributes written into the storage, which stays as the fallback). Already laid-out text is recoloured by an attribute-only storage notification over a named range; a notification over the whole document is not lazy (1.3 s at 1 MB, 59 s at 10 MB). Lines of tens of KB are too slow to colour either way. See ADR-014. Tests: `RenderingAttributeTests`.

### Fixed (TK-007a)

- A long file could not be scrolled: the text view's maximum size defaulted to its initial frame. Benchmarks of TK-008 and TK-011 for the middle and end of a file therefore measured the top of the document; they are corrected in TK-007a.
- Loaded text had no foreground colour and was drawn black in dark mode; it now uses the dynamic text colour.

### Fixed (review of TK-011 and Save As)

- Ending an IME composition no longer publishes an intermediate snapshot, and a real edit wider than what preflight knew about no longer loses its extra part: an edit is exact only when the paragraph content confirms it.
- Save As reserves the target name for the whole operation, so a concurrent Save As or open of that file is refused instead of racing.
- Save As replaces only the file the user agreed to replace (`SaveAsTarget.replacing(revision)`), not whatever happens to exist under that name later.
- Edit batches whose combined effect is no change (touching or nearby edits cancelling each other, within 256 UTF-16 units) no longer create a revision.
- The benchmark correctness check is now independent: all published change sets are replayed onto the original text and compared with the view. Results and wording in [docs/benchmarks/TK-011-results.md](docs/benchmarks/TK-011-results.md) are limited to the measured synthetic bitmap scenario; latency to the screen is not measured.

### Removed

- The standalone `Examples/CleanArchitecture` package. The maintained implementation and tests live in `Packages/IDE`.

### Known limitations

- File open/save, recovery, language services, build integration, and agent integration are not implemented in the app.
- Snapshot and edit preparation costs are O(n); large-file performance has not been validated.
- Real CJK input, dead keys, and interactive IME/undo behavior still require manual acceptance testing in the app. Automated native-view tests do not establish compatibility across supported macOS versions.
- Calling `NSTextView.shouldChangeText` successfully and then abandoning the promised edit can leave an AppKit undo action for an edit that never happened; the bridge does not repair that native history.
