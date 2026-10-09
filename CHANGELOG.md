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
- Architecture documents, a development roadmap, quality criteria, and plans for language/agent integrations.

### Fixed

- Undo of adjacent deletions by normalizing touching inverse edits into an applicable batch.
- Typing and programmatic edits merging into one undo step within the same event; caller-owned groups remain intact, and the bridge does not open groups during preflight.
- Pending autosave blocking explicit Save during composition. Explicit requests now join and promote the waiting operation, and retry if its originating task is cancelled.

### Removed

- The standalone `Examples/CleanArchitecture` package. The maintained implementation and tests live in `Packages/IDE`.

### Known limitations

- File open/save, recovery, language services, build integration, and agent integration are not implemented in the app.
- Snapshot and edit preparation costs are O(n); large-file performance has not been validated.
- Real CJK input, dead keys, and interactive IME/undo behavior still require manual acceptance testing in the app. Automated native-view tests do not establish compatibility across supported macOS versions.
- Calling `NSTextView.shouldChangeText` successfully and then abandoning the promised edit can leave an AppKit undo action for an edit that never happened; the bridge does not repair that native history.
