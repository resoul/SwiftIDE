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
- `UnsavedChangesCoordinator`: one procedure for closing a window and for quitting, so ⌘Q no longer skips the save prompt, and a window stays open when text was typed while its save was running.
- Architecture documents, a development roadmap, quality criteria, and plans for language/agent integrations.

### Fixed

- Undo of adjacent deletions by normalizing touching inverse edits into an applicable batch.
- Typing and programmatic edits merging into one undo step within the same event; caller-owned groups remain intact, and the bridge does not open groups during preflight.
- Pending autosave blocking explicit Save during composition. Explicit requests now join and promote the waiting operation, and retry if its originating task is cancelled.

### Changed

- `DocumentFileStore` now reads files and writes against an expected disk revision, returning the new revision. The in-memory store applies the same revision rules.

### Fixed (review of TK-006)

- A save no longer overwrites external changes that kept the same inode, size and modification time: the file content is checked before every replacement.
- Saving aborts before touching the original when permissions, owner, ACLs or extended attributes cannot be carried over (`cannotPreserveMetadata`), instead of continuing silently.
- Save-and-close and Overwrite no longer close the window over edits made while the write was in progress.
- Quit no longer lets through documents that changed while another document's question was open: answers are tied to the text version they were given for, and the list of windows is read again after every answer.

### Removed

- The standalone `Examples/CleanArchitecture` package. The maintained implementation and tests live in `Packages/IDE`.

### Known limitations

- File open/save, recovery, language services, build integration, and agent integration are not implemented in the app.
- Snapshot and edit preparation costs are O(n); large-file performance has not been validated.
- Real CJK input, dead keys, and interactive IME/undo behavior still require manual acceptance testing in the app. Automated native-view tests do not establish compatibility across supported macOS versions.
- Calling `NSTextView.shouldChangeText` successfully and then abandoning the promised edit can leave an AppKit undo action for an edit that never happened; the bridge does not repair that native history.
