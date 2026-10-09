# Changelog

Changes to the current SwiftIDE prototype are recorded here. Earlier repository history is not reconstructed in this file.

## Unreleased

### Added

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

### Added (TK-007c)

- Syntax colours for Swift files (ADR-014): tree-sitter parses in the background from the document's own edits (incrementally, from a private chunked copy of the text), the editor draws the result as TextKit 2 rendering attributes. Colours follow edits at once and are replaced by the next result; the document, its revisions and undo are untouched. Files over 5 MB, lines over 1000 characters and lines with over 50 coloured runs are drawn plain (the window says so for large files). See [docs/benchmarks/TK-007c-results.md](docs/benchmarks/TK-007c-results.md).
- New dependencies, pinned exactly: swift-tree-sitter 0.25.0 and tree-sitter-swift 0.7.4. Licences in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
- New module `SyntaxInfrastructure`, the `SyntaxHighlighter` port, `SyntaxCoordinator`, `HighlightState`, `SyntaxPolicy`, `SyntaxPresenter` and `SyntaxTheme`.

### Fixed (review of TK-007c)

- A document that shrank below the text that had been on screen made the syntax coordinator (and the highlighter) build an invalid range and crash; every range is now clamped to the current text.
- After an edit that changes colours far away (adding or removing `/*`), text laid out before the edit kept its old colours when scrolled back to: colours already known were taken as the union of all earlier windows. The known window is now only what the latest answer describes, a window from an older version does not count for a newer one, and scrolling tells the coordinator what is in view (TextKit reuses laid-out text without asking the validator).
- Redrawing colours of text far from the viewport made TextKit lose the last lines of a long document when the view was at its end; redraws are now limited to what is in view and the rest waits until it is scrolled to.
- The highlighter now receives its result handler through the same queue as its other messages.

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
