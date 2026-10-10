# Architecture decisions

Updated 9 October 2026. The move of the first version to TextKit 2 was agreed in the current discussion. The other details below remain a technical plan and are refined by research.

## ADR-001: Modular monolith and Clean Architecture

**Status:** accepted as a direction.

Domain/Application inside, UI/platform/infrastructure outside. AppKit is hidden behind DocumentEditingBackend. SPM targets provide compile-time boundaries. Ports belong to the consumers; a universal Shared is not introduced.

## ADR-002: Constructor DI

**Status:** accepted as a direction; the example is updated.

The Composition Root chooses TextKitDocumentBackend; tests use the headless StringDocumentBackend and the same application scenario. The backend lives as long as the DocumentSession. Factories/scopes are explicit, there is no service locator.

## ADR-003: A custom engine as a mandatory MVP

**Status:** superseded by ADR-007.

Originally Piece Tree, CoreText layout and a Core Graphics renderer were chosen ahead of the language features. This path is no longer the plan for the first version. The original algorithmic design is kept as material for future research.

## ADR-004: MainActor ownership and immutable snapshots

**Status:** accepted for the current example.

Session/backend/native UI are isolated to MainActor; the background receives independent text values. Only the backend owns the text. Full copies are allowed in the prototype with the cost measured; mutable attributed strings are not passed as snapshots.

## ADR-005: Capability-based Xcode/LSP support

**Status:** a plan; the M0 check remains mandatory.

BSP behind an adapter, a fixture matrix and a degraded UI. Local editing is available when LSP fails. Toolchain/version pinning and real integration tests come before any promise of support for complex Xcode projects.

## ADR-006: File safety/recovery

**Status:** a plan; the save race is covered in the memory slice.

Versioned save, serialization, disk conflict checks, coordinated replacement and recovery before daily use. A real filesystem adapter is not yet implemented. Undo/recovery are different systems.

## ADR-007: TextKit 2 for the first version

**Status:** accepted in discussion; the storage/layout adapter is implemented in the example.

The native NSTextView provides the basis of layout/input/editing. We implement the IDE features, the transaction bridge, metadata, syntax/diagnostic presentation, commands and integration. The IME/accessibility risk is reduced, but the checks remain.

Consequences: we check the native editor and Xcode/LSP first. Multi-cursor and split editor are postponed. A move to a custom engine requires a measured reason and a separate decision, including the migration of undo/selection/composition.

## ADR-008: Transactions, coordinates, subscriptions

**Status:** the programmatic contract v0.1 is implemented; the native contract is still to come.

Public edit ranges are UTF-16 in the source version, a no-op is determined by byte equality. Application validates the whole batch before the commit. A ChangeSet is published once to all synchronous consumers. A reentrant edit is forbidden during publication; async queues are created per consumer.

PreparedDocumentEdit with full strings is prototype-specific, O(n). It is not a promise of cheap Piece Tree edits and not the final backend preparation contract.

## ADR-009: Claude chat/agent through a replaceable provider

**Status:** recorded as a direction; implementation has not started.

Application declares CodingAgentProvider, AgentSession keeps the chat state. The initial prototype is a local CLI in read-only mode, then an Agent SDK helper for extended control of tools if needed. DI chooses the adapter; offline tests use a fake provider.

For a public integration the base auth plan is an API key or a separately confirmed supported way. We do not consider our own claude.ai OAuth/login available without Anthropic's approval. The native CLI login for local research and offering an OAuth login in a third-party product are evaluated separately.

The agent works with snapshots/versions; edits through the IDE require expectedVersion, and direct disk writes need a staging/conflict policy. Ordinary CI makes no requests to the model. Sources, limitations and stages: [Claude integration](09_CLAUDE_AGENT_INTEGRATION.md).

## ADR-010: Native transaction, composition and undo for TK-005

**Status:** implemented in Packages/IDE (NativeEditingBridge, NativeUndoCoordinator, DocumentSession); manual checking of real input sources is still to come.

Context: NSTextView already uses the backend storage, but the session so far accounts only for programmatic commits. Composition and native undo may change the storage before an application callback.

Decision: validate managed edits before mutation and reject the known violations. Unexpected native edits that have already happened are reconciled with the session through an immutable before/after diff, without changing the storage again. The transaction ID provides a single version/event per transaction that changed the text. Intermediate composition revisions are published and go to LSP; the authoritative text is the current backend. An explicit Save finishes the composition or waits for its end/cancel before the capture; autosave waits without forcing the end. The composition state has separate notifications that do not increase the text version.

One document-scoped UndoManager is provided to the native view through the platform coordinator; native and programmatic edits enter a shared history without double registration. Undo/redo always increase the text version when the text changes; the current version-based dirty marker is kept.

Consequences and checks: additional snapshots/diffs may cost O(n); measure the costs. Check callback deduplication, refusal before mutation, reconciliation, IME cancellation/unmark without a text change, the save gate, LSP ordering and a single undo history. The contract and the order of implementation are in [docs/08](08_TEXTKIT_IMPLEMENTATION_PLAN.md); revisit after a reproducible violation of IME or of the budgets.

## ADR-011: Open, save and disk revisions for TK-006

**Status:** implemented in Packages/IDE (`AtomicDocumentFileStore`, `FileRevision`, `DocumentRegistry`, `OpenDocumentUseCase`, `ReloadDocumentUseCase`, `SaveDocumentUseCase`).

Decision:

- **The revision** = the file identifier (device+inode), the size, the mtime in nanoseconds and the SHA-256 of the contents, computed on reading and writing. A conflict is determined **by content only**: before every replacement the file is read again and its SHA-256 is compared with the expected one. Metadata cannot be trusted — the size and mtime can be restored by the program that changed the file (checked by a test: the same inode, size and mtime, different bytes). So every save costs a read and a hash of the file (O(n)); a match of content is not a conflict (`touch`, an editor replacing the file with the same bytes). A difference in content, a deleted file or an already existing "new" file is `FileStoreError.conflict`, and no write is made.
- **The expectation** is passed by the port explicitly (`SaveExpectation.revision` / `.overwrite`). The revision is captured together with the snapshot, so a late success of N does not mask the edits of N+1 and a chain of saves does not conflict with itself. An overwrite is possible only through an explicit `overwritingExternalChanges` after the user's choice.
- **Reading**: strict UTF-8 and UTF-8 BOM with a size limit (100 MB by default, the limiting value will be determined by TK-008). Binary files are detected by NUL bytes, not by extension; UTF-16/32 by BOM is `unsupportedEncoding`; invalid bytes are not replaced. A file that changed during the read is rejected. The BOM is save metadata, line endings stay in the text.
- **Writing**: a temporary file in the same directory, carrying over the mode, owner, ACL and xattr of the original file (**any failure of the transfer aborts the save before `rename`**: `cannotPreserveMetadata`, the original is untouched), `fsync`, an atomic `rename`, all inside an `NSFileCoordinator` write. A symlink is written through to its target and is not replaced itself. A read-only file is not replaced by bypassing its permissions. The temporary file is deleted on any error.
- **The identity of a document** is the file, not the name: the canonical path (symlinks resolved) plus the `FileIdentity` (device+inode) of the last read or written revision, so two hard links of one file open as one document. An atomic save changes the inode, so the identity is taken from the session's current revision and is not fixed on opening. The consequence and policy: after saving through one name the second hard link is already a different file (the atomic replace does not touch it and breaks the link) and opens as a separate document; links are not preserved. Parallel opens of one file reduce to one session; a cancelled open registers nothing.
- **Closing and quitting** — one `UnsavedChangesCoordinator` procedure for the window and for ⌘Q (AppKit does not call `windowShouldClose` when the application quits). A successful write does not permit closing if new edits appeared during the write: the window stays open. The consent is tied to the **version**: "Don’t Save" permits discarding the text that the user saw, not any later edits (when a window closes, an edit under the open sheet keeps the window open). On quit the list of documents is read again after every answer: a document already agreed on or saved but modified again, and a window that appeared during the questions, are asked about again. `reply(true)` is possible only after a pass without suspensions in which all the documents are clean or discarded in the current version. One question per document at a time; the quit stops at the first answer "cancel" or an unsuccessful save.
- **Reload** is an ordinary undoable edit of the whole text; if the user typed during the read, the reload is rejected (`staleVersion`), the input is not lost.

Limitations (honestly): BSD file flags (hidden/immutable), the creation time and hard links are not preserved; an ACL "deny delete" makes the file irreplaceable by the atomic replace (the save will refuse with permissionDenied). Coordination protects only against writers that are coordinated too — between the check and `rename` a TOCTOU window remains for an ordinary `write(2)` by another program; `fsync` does not guarantee data survival on power loss; extended attributes and ACLs are carried over, but the behaviour on network volumes has not been checked. Out of scope: Save As, the file watcher, the recovery journal, a diff of the conflict.

## ADR-012: The cost of a keystroke is proportional to the edit, not to the file

**Status:** implemented (TK-011). Data before — [TK-008](benchmarks/TK-008-results.md), after — [TK-011](benchmarks/TK-011-results.md).

Context. Measurements of the full pipeline (input → commit → layout → draw) showed that drawing the visible part (≈4 ms), scrolling (≤6 ms) and opening 100 MB (≈0.8 s) hardly depend on the file size, while the keystroke latency grows linearly: ≈20 ms per 1 MB, ≈160 ms per 10 MB, ≈1.5 s per 100 MB. The sum of three operations over the whole text explains the latency completely: a copy of the text from the backend, a byte-by-byte comparison and the planning/validation of an exact edit through `Array(utf16)`. Our pipeline is to blame, not TextKit. The same operations cost 270–350 ms at 10 MB in a programmatic edit and in undo (a diff of two strings). The p95 ≤ 16 ms budget is already broken at 1 MB.

Decision. There must be no operations over the whole text on the edit path. The invariants:

- **The session does not keep a copy of the text.** It keeps `version`, `savedVersion`, the length in UTF-16 (updated by the delta) and `knownGeneration`. `text` and `snapshot()` are assembled from the backend on demand (save, `didOpen`, reload) and stay paired with `version`: the comparison is synchronous, there is no window of "new text with the old version".
- **The backend provides O(1)/O(range) access**: `utf16Length`, `unit(at:)`, `substring(in:)`, `editGeneration`. The edit planner works with this interface (`TextSource`), not with a string: boundaries, surrogate pairs and overlaps are checked without a copy, a no-op is determined by comparing the replaced fragment.
- **`PreparedDocumentEdit` contains no `sourceText`/`resultText`**, only the edits, the replaced fragments (for inverse and undo) and the lengths. `inverseEdits` is built from the replaced fragments in O(edit).
- **A native edit is described by its own range.** The bridge takes it from `editedRange` + `changeInLength` (the `didProcessEditing` boundary): a replacement in "before" coordinates = `(loc, len − Δ)`, the replacement text is the substring of the result by `editedRange`. The storage widens `editedRange` to the end of the paragraph (because of attribute fixing), so the precision is determined not by the match of ranges but by the content: if `shouldChangeText` gave a single edit and the paragraph after it (context up to 64 KB) equals the paragraph before with that edit substituted into it, the edit is exact; otherwise the replacement covers all the changes but may include unchanged text (`isReconciled`). For a paragraph longer than 64 KB it cannot be confirmed, and every keystroke is published as a region. The view's compound operations (`insertText`/`setMarkedText`/`unmarkText`) accumulate the union of ranges (`EditAccumulator`) and publish one replacement. NSTextView's own undo/redo go the same way in O(edit), a diff of two strings is no longer needed.
- **An unnoticed mutation** is caught by the `editGeneration` counter (incremented by every pass of editing characters in the storage) and a length comparison, both checks O(1). If the counter diverged from the one known to the session, the edit is described as a single replacement of the whole document (`isReconciled`) — this is O(n), but only in an emergency, not on every keystroke.
- **Net-zero operations**: `unmarkText` without a text change is determined by comparing the text of the marked range before/after (O(marked)); an exact edit that replaces a fragment with itself is determined from the captured replaced fragment. In both cases the version does not grow, but `knownGeneration` is updated.

What we lose and how it is compensated. Before, every native edit was compared with the full text. Now we trust the `editedRange` contract (it covers all the changes) plus the check of the length and the counter. The strong verification is done by the tests: the fixture keeps an independent copy of the text, applying the published `DocumentChangeSet`s to it in order, and after every event compares it with the view's text; a random test compares the accumulated replacement with the true "before/after" on series of edits with random surrogates and CRLF. The measurements do the same: replaying all the published changes must give the view's text.

Refinements after the review: (1) the end of a composition (`unmarkText`) is published only if the text of the marked range changed, an intermediate snapshot with a "closed" composition is not visible to the subscribers; (2) an edit for which the preflight knew only part of the changes does not lose the rest: the whole `editedRange` is accounted for; (3) the planner does not create a revision for batches whose total effect is no change: touching edits and close edits (within `cancellationReach` = 256 UTF-16 units) that give the same text are dropped; beyond this limit mutually cancelling edits are not recognized (expensive and rare).

What it does not solve. A giant line (tens of KB in one line): the cost of laying out a whole paragraph is inside TextKit and grows with the length of the line; this is a separate decision (a long-line mode), see TK-008.

The order of implementation: (1) the backend port and `TextSource`, the planner and `PreparedDocumentEdit` without full strings; (2) `DocumentSession` without `committedText`, the generation counter and the length comparison; (3) the bridge: describing an edit by `editedRange`, `EditAccumulator`, net-zero for unmark; (4) the undo coordinator and `StringDocumentBackend` on the new interface; (5) remove `TextDiff` from the hot path (keep it only for an emergency replacement, if needed); (6) repeat the measurements with the same tool and record before/after. The criterion: the input p95 at 10 MB is within a few milliseconds above TextKit's cost, a programmatic edit and undo do not grow with the file size.

## ADR-013: Save As

**Status:** implemented in Packages/IDE (`SaveDocumentUseCase.saveAs`, `DocumentSession.isUntitled`, `DocumentRegistry`) and in the application (⌘⇧S, ⌘S for an unnamed window).

- **The document moves.** After the write under the new name the session receives this path, the revision and `savedVersion`; the previous file stays as it was. An unnamed document (`isUntitled`) has no file, and an ordinary save for it is the error `SaveError.untitled`, so ⌘S on it opens Save As.
- **The name is free or replaced explicitly.** For a new name the expectation is "no file" (`.revision(nil)`), so a file that appeared after the name was chosen is a conflict, nothing is written. Replacing an existing file (`replacingExistingFile`) is the answer of the user in the system panel, the expectation `.overwrite`.
- **One file — one window.** If another document is already open under this name, Save As is rejected (`targetOpenElsewhere`): two editable windows of one file would overwrite each other. The check is by path; a hard link under another name is not caught by it (as everywhere, the identity of a file is known only after a write).
- **A registry without a path index.** A document changes its path, so the registry keeps a list and searches by the session's current path and the file identity; unnamed ones do not take part in the path search. An unnamed document enters the registry at the first Save As.
- **The same guarantees as Save:** ending the composition before the snapshot, one save per document at a time (the second is `saveInProgress`), text typed during the write stays unsaved, the write is atomic with the new file's metadata carried over under ordinary permissions.
- A Save As under the document's own name is an ordinary save.
- **The name is reserved for the whole operation.** `DocumentRegistry.reserve` takes the target path before the write and releases it after (`defer`): a second Save As to the same name and an open of the file that is being written now get `targetBeingSaved` / `OpenDocumentError.beingSavedElsewhere`, not a race.
- **The consent is a specific file, not the fact of existence.** The system panel asks about the replacement; `SavePanelConsent` (the panel's delegate) remembers the file's revision at the moment of confirmation, and the write goes as `SaveAsTarget.replacing(thatRevision)`. If the file managed to change or appeared later — a conflict, nothing is written. For a new name — `SaveAsTarget.newFile`.

## ADR-014: Gutter and syntax highlighting (TK-007)

**Status:** accepted (tree-sitter, the highlighting threshold of 5 MB — refined by a measurement in 007c); implementation step by step. Split into three steps, each with its own measurements: 007a — the line index and gutter, 007b — a prototype of the way to apply attributes, 007c — tree-sitter.

Context. The editor already keeps the cost of an edit at O(edit) (ADR-012), and new features must not bring O(file) back onto the keystroke path. Line numbers are needed at once, but a "line number by offset" without an index costs O(file). Highlighting must not change the text, the document version and the undo history (docs/08, §5).

### 007a. The line index and gutter

**Implemented** (`LineIndex`, `DocumentLineIndex`, `LineNumberRulerView`); data — [TK-007a](benchmarks/TK-007a-results.md). Building the index at 100 MB takes 161 ms on the main thread; we do not split it into time slices until it gets in the way.

- **`LineIndex`** is a pure type in IDEApplication, without AppKit. A line ends with `\n`, `\r\n` or `\r` (LSP determines lines the same way, it will be needed in TK-010). The index keeps the lengths of lines in chunks (about a thousand lines per chunk) with sums per chunk: offset → line number and line number → offset in O(log n + chunk), an edit in O(edit + number of chunks).
- **The index is built from `DocumentChangeSet`, not from reading the backend.** This decouples it from the moment of publication (the backend may run ahead because of a deferred edit). Splitting and joining `\r\n` at the edge of an edit are determined by the end-of-line flag the index keeps. The O(1) self-check: the total length of the index equals the session's length; a divergence or an `isReconciled` of the whole document — a rebuild from a snapshot.
- **The initial build** at opening is one pass over the text. For 100 MB (≈3.8 million lines) we first measure the cost in the same benchmark tool and only then decide whether a build in time slices is needed; we do not complicate it in advance.
- **The gutter is an `NSRulerView`** on an `NSScrollView` (EditorUI), a system mechanism synchronous with scrolling. It draws only the visible range: fragments are taken from `textViewportLayoutController`, without forcing a layout of the rest. The number is put at a fragment that begins at the start of a line; wrap continuations are empty; for an empty last line — the extra line fragment. The width depends on the number of digits (the total number of lines is known from the index) and does not trigger a layout.
- Diagnostics and changed-lines (docs/01, P1) — later, on top of the same gutter. We do not do folding.

### 007b. How to apply attributes

**Decided by a prototype** ([TK-007b](benchmarks/TK-007b-results.md)): way 1, rendering attributes. Below is the original statement, then the outcome.

Two candidates, chosen by a measurement on files of 1/10/100 MB and a giant line:

1. **`NSTextLayoutManager` rendering attributes** (`setRenderingAttributes`/`addRenderingAttribute`): the storage is not touched, there are no edited notifications, undo is not cluttered, only drawing is invalidated. A limitation: colour, underline, background, but not the font. What is unknown and what the prototype checks: whether they survive an edit nearby and what colour freshly typed text gets.
2. **Attributes in the storage** (`addAttribute` under `beginEditing`): work everywhere, but every write makes TextKit re-create paragraphs (expensive on long lines) and goes through our observers (they are accounted for as attribute-only, create no revision, but it is extra load).

The preference is way 1, if the prototype confirms it; otherwise way 2 only for the visible range.

**Outcome.** We take way 1. It was confirmed: it does not change the text, `editGeneration`, the revisions and undo; the colours follow the edits (text typed inside a word is plain); the validator (`renderingAttributesValidator`) is called lazily, for fragments that have been laid out; the cost of typing is +2.5 ms at any file size (p95 8.6–9.5 ms against 6.2–6.7 without colour). Way 2 is cheaper by ≈1 ms per keystroke, but changes the storage and requires adding colours by hand on scrolling; it stays as a fallback (measured).

The rules for 007c that follow from the prototype:

- **Application.** The colours are set by the validator: for a fragment it takes the tokens of its range from the already prepared highlighting state and calls `setRenderingAttributes`. It parses nothing and waits for nothing: no ready tokens means the fragment is plain.
- **Repainting what has already been laid out** — only through `NSTextStorage.edited(.editedAttributes, range:, changeInLength: 0)` under `beginEditing/endEditing`. Other ways (`invalidateRenderingAttributes`, `invalidateLayout`, `setNeedsDisplay`) do not work in a live window. The bridge and the storage observer see a pass without `.editedCharacters` and publish nothing.
- **The range is always named and bounded.** A notification over the whole document is not lazy: 1.3 s at 1 MB, 59 s at 10 MB. The visible area is updated in ≈10 ms at any size. What changed outside the area is remembered as stale (a set of ranges) and updated when the viewport reaches it.
- **Typed text is plain until the next pass**; after an edit its range and what the parse changed are updated.
- **Do not update during an IME composition** (`session.isComposing`); not checked, manual acceptance.
- **We do not colour lines of tens of KB:** at 51 KB typing takes 490 ms, at 102 KB 911 ms. The line-length threshold will be determined by 007c.
- The `edited(.editedAttributes)` notification is an observable behaviour of TextKit, not documented; it is fixed by the automatic tests (`RenderingAttributeTests`), which on new macOS versions will also show a breakage.

### 007c. Parsing: tree-sitter

**Implemented** ([TK-007c](benchmarks/TK-007c-results.md)). The outcome and the differences from the original design are below; the original text is kept as the statement.

**What was done.**
- The dependencies, pinned exactly: `swift-tree-sitter` 0.25.0 (pulls `tree-sitter` 0.25.10) and `tree-sitter-swift` 0.7.4-with-generated-files; licences MIT, BSD-3, MIT, the texts in [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md). The highlight query is copied from the grammar without changes into a resource of the module (the grammar's own resource bundle cannot be reached through its Swift API).
- The `SyntaxHighlighter` port (IDEApplication): `connect`, `reset(text:version:)`, `edit(_:)`, `requestHighlights(in:version:)`, `stop()`; all methods return at once, messages are processed in order, the answer names the version. The `TreeSitterHighlighter` adapter (module `SyntaxInfrastructure`, the only one that knows the parser).
- `SyntaxCoordinator` (IDEApplication, main thread): forwards edits, asks for the colours of the visible window ± a margin (6000 units), keeps the `HighlightState`, asks for the colours again after every edit, discards results of a non-current version and starts from scratch on a length mismatch. Ranges given to it before an edit it always trims to the current text. It hands the changed colours to redraw only for what is in the viewport; the rest waits in `HighlightState.dirty` (which follows the edits) and is handed over when scrolling reaches it. During an IME composition nothing is redrawn.
- `HighlightState`: the window's colours that follow the text (shift, trim, a cut by an edit; inserted text has no colour) and are replaced entirely by a new window result. **The window is what the last result describes**, and only it counts as known; the colours left from earlier windows outside it are kept as a basis for comparison but are not considered right. A replacement returns the ranges where the colour really changed, and only they are updated on screen.
- `SyntaxPresenter` + `SyntaxTheme` (EditorUI): the rendering attributes validator (the 007b decision), clears a fragment's colour before writing (TextKit does not reset it by itself), asks for colours for fragments outside the known window (`demand`), updates the changed ranges through a storage attributes notification. It watches scrolling and changes of the text's height and tells the coordinator what is in the viewport: when returning to text that has already been laid out, TextKit does not call the validator, and without this the colours computed before an edit would stay on screen. The `SyntaxPolicy`: 5 MB per document, 1000 characters and 50 coloured spans per line.
- Connected in the application window for `.swift` files; in large files the window says so in the subtitle.

**Differences from the original statement.**
- The parser's mirror of the text is not a set of immutable chunks with snapshots but **its own mutable copy** (`ChunkedText`), changed only by edits from the ordered queue. Snapshots are not needed because the text is not shared with other threads.
- The row/column for `TSInputEdit` are taken from **the parser's own `LineIndex`**, which it maintains with the same edits, not from the main thread's index (the order of the session's subscribers is undefined).
- The colour state is kept **for a window** around the visible one, not for the whole document; what is missing is requested when the validator meets a fragment outside the window or when scrolling brings text outside the window into the viewport. A queue of "stale off screen" is needed and exists (`HighlightState.dirty`): without it either old colours remain or the redraw of distant fragments tears the layout (see below).
- The line-length threshold is complemented by a threshold on the number of coloured spans (the cost of editing a line grows with the number of spans, not with the length).

**Numbers:** see the report. The first colours 1.6 s and +503 MB at 10 MB, hence the 5 MB threshold; the time to receive a result 12 ms (up to 1 MB) and 46 ms (10 MB; to a ready picture +6 ms, see "Review, second round"); typing with colour p95 9.8 ms at 10 MB in a synthetic scenario.

**Fixes after a check (2026-10-10).** Two errors were confirmed and fixed; two more were found along the way.
- After the document was shortened the coordinator crashed on creating a range: the remembered viewport stayed beyond the end of the text. Now any range is trimmed to the current text (in the coordinator, in the highlighter and on redraw).
- After an edit that changes colours far away (inserting/deleting `/*`), the previously viewed area was not requested again: the union of all the past windows counted as "known", although the new result described only the last one. The window is now only what the last result describes; moreover, a window from an earlier version is not considered known for the new one until an answer for it has arrived.
- **TextKit loses the last lines** if right after an edit a wide range around the viewport is repainted at once (`edited(.editedAttributes)`) while scrolling to the end of a long document (the last five lines disappeared from the screen; reproduced in a live window, not reproducible without colour and without the repaint). The repaint is limited to the viewport (checked, the lines are in place), the rest waits in `dirty` and is handed over on scrolling. The cause in TextKit has not been established, the rule was established by experience.
- The highlighter received the results handler through a separate task, not through the shared queue: on a loaded machine the first answer could be lost. Once in a full test run the highlighter did not answer within 20 s; it could not be reproduced deterministically, the order of messages was fixed and pinned by a load test, which gives no guarantee.

**An unterminated `/*` (found in a manual check).** The tree-sitter-swift grammar recognizes a block comment only together with the closing `*/`; an unterminated `/*` it reads as an operator, and the code below stays coloured. Swift reads such a comment to the end of the file (Xcode shows it that way too). After every parse the highlighter looks for the first `/*` that the tree considers neither a comment, nor part of a string, nor a line comment (by the text of the copy and the node type: an operator), and colours everything from it to the end of the text as a comment on top of the tree. The search goes over the highlighter's copy of the text (≈ 3 ms at 5 MB in the background, colour lag at 10 MB 45 → 51 ms). Nested comments and `/*` inside strings, multi-line strings, extended regex literals `#/…/#` and after `//` are checked by tests: the rule does not fire. An ordinary regex literal with an escaped slash (`/a\/b/`) is read incorrectly by grammar 0.7.4 even without any `/*` (the code after it loses colours); this is a limit of the grammar, and the rule does not turn the file into a comment because of it (a test).

**The second round of checking (2026-10-10).** Three remarks were confirmed; all were fixed, each with a test that failed before the fix.
- **The 5 MB limit applied only when the window was opened** (P1). A small file into which a large text was then pasted, or which was reread having grown, stayed highlighted without a limit: the memory protection was bypassed by an ordinary edit. Now the highlighting is watched by `SyntaxColouringController` (`IDEApplication`): after every change of the document it compares the length with the limit (two numbers), on exceeding it stops the coordinator and the presenter, the highlighter **frees the tree and the copy of the text** (`stop()` now does it at once, without waiting for the object's death), the presenter removes the colours from the screen. The highlighting can come back when the text became 10% smaller than the limit (hysteresis: a file at the boundary does not start and stop parsing on every keystroke; 10% is a provisional value). The controller subscribes to changes **before** the coordinator, and the session now calls observers in the order of subscription (before — in dictionary order), so an edit that made the file too large does not reach the highlighter: it is not made to parse a paste of several megabytes only to throw it away at once.
- **Save As did not change the choice of language** (P2). After `.txt → .swift` highlighting did not appear, after `.swift → .txt` it stayed. The window calls `colouring.refresh()` after Save As; the subtitle ("syntax colours off: large file") is now built from the controller's state and does not lie after a name change. Along the way it was found that: a presenter created for text that has already been laid out (highlighting was turned on in an open window) was not called by TextKit and therefore did not learn what was on screen; now it asks by itself on creation. And: a released presenter did not remove the colours already drawn (TextKit keeps a fragment's attributes even after the validator is removed); now it removes them, on the whole document this costs 0.02 ms (1 MB) and 0.01 ms (5 MB) plus 3 ms of redraw.
- **The "colour lag" ended before drawing** (P3). That was the time to receive a result, not the time to the picture. Now both are measured, and a series of 60 keystrokes without waiting for the background was added. The series showed a real defect: at 10 MB every keystroke queued a colour request, the background parsed the text for each one, and the colours were ready **2.2 s** after the last key. Now a request for which a newer one is in the queue is skipped (the editor would throw its answer away anyway): 57 ms. The search for an unterminated `/*` was evaluated separately (5 ms per request at 10 MB, O(n) in the file size, not in the edit). The numbers: [TK-007c, second round](benchmarks/TK-007c-results.md).

**Known limits.** One language; the extension is taken from the window's path at opening and at Save As; the line thresholds are provisional; during a composition not checked manually; the mirror and the tree are per window.

### 007c: the original statement

- **Dependencies (SwiftPM, we pin versions):** `tree-sitter/swift-tree-sitter` (a wrapper over the runtime) and the Swift grammar `alex-pinkus/tree-sitter-swift` in the variant with ready generated files (`*-with-generated-files`, otherwise a generator is needed). The parser is C, thread-safe with a separate `TSParser` per thread. A new module `SyntaxInfrastructure` (the port is in IDEApplication: `SyntaxHighlighting` gives tokens for a range; the adapter is in infrastructure); EditorUI knows only tokens.
- **Incrementality.** The session's edits are translated into `TSInputEdit`; the row/column are taken from `LineIndex`. While a parse is in progress, new changes accumulate and are applied as a batch; stale results are discarded by the document version (like stale LSP answers).
- **The text for parsing.** Parsing happens off the main thread, and the storage cannot be read from there; copying the whole text on every edit is not allowed (ADR-012). The highlighting keeps its own mirror of the text as immutable chunks (about 64 KB): an edit replaces one or two chunks, a snapshot for the background thread is a copy of the array of references. This is the same idea as in LineIndex, and a common type can be used for both.
- **What we highlight.** The highlight query (`highlights.scm`) is run only over the visible range plus a margin; the rest is computed at idle. Application — in batches on the main thread, no longer than a fraction of a frame.
- **Limits.** For files above a threshold (5 MB is proposed to start, refined by measuring the initial parse) and for lines longer than a threshold, highlighting is switched off explicitly, with a note in the window, not silently. Parsing is a background task with cancellation; input does not depend on it.
- **What we do not do in this task:** SourceKit semantic tokens (on top of the lexical ones, later), themes beyond the light/dark system ones, other languages (added as grammars).

### Alternatives

- **A hand-written Swift lexer:** no dependencies and very fast, but without structure (contextual keywords, interpolation, multi-line strings, macros) it would have to be maintained by hand; useless for future folding and structure navigation.
- **SwiftSyntax:** an exact Swift parser, but a heavy dependency, Swift only, limited incrementality; excessive for highlighting.
- **LSP semantic tokens only:** need a running SourceKit-LSP and a project; highlighting must not depend on them.

### Risks

- TextKit 2 rendering attributes are little documented: the 007b prototype is mandatory before the 007c code.
- The grammar's generated files are tens of thousands of lines of C: build time, repository size (the dependency stays external, not vendored).
- Parsing large files loads memory with the text mirror (about the file's size in UTF-16): it is enabled only below the threshold.

## ADR-015: Long lines (TK-012)

**Status:** step 1 is implemented; step 2 (a prototype) was carried out, the result is negative for adoption: [report](benchmarks/TK-012-step2-prototype.md). Data — [TK-012](benchmarks/TK-012-long-lines.md), [TK-008](benchmarks/TK-008-results.md).

Context. TextKit lays out a paragraph as a whole; the cost of typing grows with the length of the line, not with the size of the file: ≈ 9 ms at 12,000 characters, 15 at 16,000, 33 at 24,000, 84 ms at 51 KB, 1.5 s at 1 MB. A minified file with such a line will hang the window. Turning off wrapping (the only TextKit setting that could help) is worse: 257 ms instead of 84 at 51 KB.

Decision, step 1 (by the user's choice: protection now, a prototype later; by default warn and open as usual).
- **What counts as a long line:** more than 16,000 UTF-16 units without a terminator (`LongLinePolicy`). The boundary is where the p95 of typing leaves the 16 ms budget.
- **Detection:** the longest line from `LineIndex` (by a piece: a query in one step per piece). `LongLineMonitor` looks at it after every change, so the warning appears when a long line is pasted and disappears when it became shorter.
- **The warning:** a bar above the text with two buttons: "Make Read-Only" (the view becomes non-editable, can be allowed back) and "Keep Editing" (do not remind again for this document). By default the file opens for editing. Highlighting for such lines is already switched off by the ADR-014 policy.
- **What step 1 does not do:** it does not speed up editing a long line; it does not block programmatic edits in "read-only" mode; it does not measure real minified files.

**The result of step 2 (2026-10-10).** A subclass of `NSTextContentStorage` that hands out a long paragraph in pieces works and speeds up typing in a 1 MB line from 1533 to 21 ms (p50), but in a random test TextKit goes into an infinite layout loop on edits of line breaks next to a split paragraph (2–3 runs out of 6; without such edits and without splitting — 0). The cause was not found, three mitigations did not help. Besides: the line is cut off at the piece boundary, and the "by paragraph" commands (Ctrl+A/E, Option+↑/↓ with selection) stop at the edge of a piece. It cannot be adopted in this form; the options (stop at step 1, look for the cause, show a truncated line) are in the report, the decision is the user's.

Step 2 (the original statement). The hypothesis: show a long line in parts without changing the text (the document stays one line): its own `NSTextContentManager` hands TextKit paragraphs no longer than a few KB, and edits are translated between an offset in the document and an offset in the part. What is unknown: whether the selection, IME, undo and search of NSTextView will withstand such a substitution; the cost of translating coordinates; the cost of all this on ordinary files. The criterion: an edit in a line of 1 MB fits the budget without changing the behaviour of ordinary files. If the prototype does not get anywhere in reasonable time, step 1 stays.

**The user's decision after the prototype (2026-10-10).** TK-012 stays at step 1 (the warning and "Make Read-Only"). Step 2 with splitting the line for layout is **not shipped**. The cause of TextKit's hang on Enter/Backspace next to a split line need not be investigated now, it does not block the other tasks. The next work on long lines is a separate prototype of **truncated display**: the hidden part of a line does not take part in layout, the source text stays whole; the first variant is read-only for truncated lines (editing such a line is forbidden). Before implementing it an assessment of compatibility with search, copying, selection and line numbering is needed (in the plan: TK-013).

## ADR-016: Recovery of unsaved text (TK-006)

**Status:** implemented (checked by hand in a window only partly: F1 and F2 passed on 2026-10-10, the rest is not checked, see [manual acceptance](10_MANUAL_ACCEPTANCE.md), section F). The requirement is P0 from the [product plan](01_PRODUCT_AND_IMPROVEMENTS.md): after a crash the restart offers to bring the text back, a conflict with the disk is not overwritten.

**The user's decisions (2026-10-10).** Start with recovery, the watcher later; keep **a delayed snapshot of the text**, not a journal of edits; at launch **ask per document**.

**What was done.**
- The `RecoveryStore` port (`IDEApplication`): `write` replaces the record of a key, `remove`, `pending`. The key of a document with a file is its path (the same record in every launch), of a document without a file — its own id. A record: the text, the encoding, the path, **the file revision the text is counted from**, the time.
- `RecoveryCoordinator` (per document): after the last edit, in **2 s** it writes a snapshot, but no later than **10 s** after the first unsaved edit, however continuously one types; when the application loses focus it writes at once (`flush`). When the document became clean (Save, Save As), the record is deleted. All operations on the store go through one queue, so a slow write cannot land after a later deletion. While IME holds marked text, the snapshot is postponed. A write failure is not hidden: the state is `failing`, the window subtitle says "recovery failing", the next edit tries again.
- Size: a document larger than **16 MB** (UTF-16) is not saved, the subtitle says "recovery off: large file", an already existing record is deleted (a record of old text would confuse more than help). The reason for the limit: the copy of the text is made on the main thread, 2.6 ms per 1 MB, 26 ms per 10 MB, 42 ms per 16 MB ([TK-011](benchmarks/TK-011-results.md), `snapshot_ms`); it is paid once per pause, and with continuous typing once per 10 s.
- `RecoveryJournal` (`FileSystemInfrastructure`): `~/Library/Application Support/SwiftIDE/Recovery/`, one file per document, the name is a hash of the key (any key stays inside the directory). The format: a marker line, a JSON line (key, path, base revision, length, SHA-256), the UTF-8 text. Written through a temporary file in the same directory and `rename`, `fsync` of the file. The directory is 0700, the files 0600 (they contain source code). On reading the marker, the length and the SHA-256 are checked: a truncated or modified file is **not offered as the user's text** but goes into the list of unreadable ones and is shown in the window. Temporary files older than a minute (from a dead write) are deleted.
- `RecoveryRestorer` + `AppDelegate`: at launch, "Restore / Discard" is asked for every record. The disk is classified: unchanged, **changed**, gone, unreadable, the document had no file. Restoring **writes nothing to disk**: the text becomes an ordinary unsaved edit of the file (undone with ⌘Z). If the file has changed since, the session receives the old base revision, and **Save gives an ordinary conflict** (Overwrite / Reload / Cancel), as for any external edit. A gone or unreadable file and a document without a file open as Untitled. If a window with this file is already open and has unsaved work, that is newer and stays; the record will be replaced by its own. The old record is deleted only after the restored document has written its own (otherwise a crash in between would lose the text).
- Quit: "Don't Save" on quit and closing a window without saving delete the records of these documents (the user agreed to lose them); a crash does not touch them.

**Checks.** The coordinator (19 tests: timers on a manual clock, the queue order, IME, failure, the limit, Save As with typing during the write), the journal (16: lossless exchange, damage, permissions, temporary files, atomicity), restoration (10: classification, the conflict preserved, an inaccessible file) and end-to-end tests on real files with a "crash" between launches (3). Checked by mutations: deleting the record on Save, the 10 s limit, the queue sequence, IME, cleaning the old key, the checksum, writing directly instead of `rename`, the directory permissions, cleaning temporary files, the file name by key, the base revision on restore, the protection of newer work.

**Fixes after the review.**
- A restored document is judged against the revision from the record **always**, not only if the scan found `.changed`: the file could change while the "Restore / Discard" question was on screen, and Save would then silently overwrite someone else's edits. If the bytes are the same, the store sees no conflict.
- The old record is deleted only after **confirmed** writing of the new one: `RecoveryCoordinator.flush()` returns a `Safekeeping` receipt: "nothing to keep" or "the store holds the text of version N under key K" (nil — a write failure, the document is over the limit). Version N is the one the write captured: while the store worked the document could have moved on, so the receipt guarantees exactly this text and no more. `RecoveryRestorer.retire(...)` removes the old record only if the version in the receipt is not older than the restored text; otherwise the old record stays the only copy. Before, `flushRecovery()` returned `Void`, and the application deleted the old record unconditionally.
- Quit: releasing the recovery copies ("Don't Save") is now part of `UnsavedChangesCoordinator.canQuit(documents:release:reinstate:)`. It takes time in which one can type text or open a window, so everything is checked again after it (new text — a new question, a new window — a question, the document is released again), and on a refusal `reinstate` restores the protection. `RecoveryCoordinator.withdraw()/resume()` instead of stopping forever: the quit can still be cancelled. The final check still goes without suspensions.

**Known limits.**
- **Two instances of the application** (for example, a second `swift run`) share the directory: at launch the second will offer to "restore" the first one's live unsaved documents. There is no locking; an ordinary launch through LaunchServices does not create a second instance.
- The `fsync` of the temporary file does not guarantee survival on power loss (as with saving files).
- The restore dialog, going to the background, ⌘Q and the windows were checked only by component tests; the live window was not checked.
- The parameters (2 s, 10 s, 16 MB) are provisional, with no measurements on other machines. The write pause on the main thread at 16 MB is up to ≈ 42 ms.
- Unreadable records are not deleted: they stay in the directory and are shown at every launch until removed by hand.
- The size of the directory is not limited: records live while the document is unsaved.

## ADR-017: File watching (TK-006)

**Status:** implemented (checked by hand in a window only partly: G1–G7 passed on 2026-10-10, the rest is not checked, see [manual acceptance](10_MANUAL_ACCEPTANCE.md), section G).

**The user's decisions (2026-10-10).**
- A clean document (no user edits), the file changed on disk: **re-read it by itself** and show a bar "changed on disk and reloaded" with an Undo button.
- A document with unsaved edits, the file changed: **a Reload / Keep Mine bar**, do not touch the text.
- The file deleted or renamed: **a bar "deleted or moved" with a Save As button**, the document stays open.

**What was done.**
- The `FileWatching` port (`IDEApplication`) says only "something happened, have a look": events come in batches, late and for nothing. The store port gained `currentRevision(path:assumingUnchangedFrom:)`: the file's revision by bytes, and if the identity, size and modification time are the same as the known ones, the file is not read (a directory event is no reason to read 100 MB).
- `ExternalChangeMonitor` (per document): after an event it waits 250 ms (editors write in several steps), looks at the file, waits 300 ms and looks once more; it decides by the **bytes**, not by the event, and only when two looks agree. The document's own save, `touch` and a rewrite with the same bytes are not a change (the document's revision matches the file). A file that vanished for a moment (an editor saving by "delete and create") is not considered deleted. A series of 20 events is one look.
- A clean document: `ReloadDocumentUseCase` (an ordinary edit, can be undone, published like all). If during the reading of the file the user typed or an IME composition was going on, the reload does not overwrite their input: instead of it a Reload / Keep Mine bar. A modified document is never touched.
- "Keep Mine" is silent about this version of the file, but not about the next one; the conflict on Save remains (checked by a test). "OK" dismisses the bar, and the same situation is not announced again until it changes. A "reloaded" bar is not dismissed by later write events until it is closed. If the file cannot be read as text (binary, not UTF-8), the bar states the reason.
- Save As moves the watching to the new name; a document without a file is watched after the first save. Closing the window stops the monitor.
- `VnodeFileWatcher` (`FileSystemInfrastructure`): the kernel's `DispatchSource` events on the file and on the directory. The file alone is not enough: an editor that saves with "a new file and rename over it" leaves the descriptor on the old, already unlinked file, and all further changes are not seen. So a delete/rename/revoke event and a change of what lies under this name in the directory reopen the file (two independent paths, intentional redundancy). Directory events concern all the names in it, so they are taken into account only if the file under our name changed: a noisy directory does not wake the document.
- In the window there is one bar above the text: an external change matters more than "read-only" and than the long-line warning (it is about the user's work).

**Checks.** The monitor (24 tests on a manual clock and a manual observer), the watcher on a real file system (10: an in-place edit, a replacement through rename and the next edit of the new file, 15 replacements in a row, deletion and return, a rename, a file that does not exist yet, `touch`, noise of neighbouring files, cancellation, the store's own write), two checks of the store's cheap revision and end-to-end ones (7: a real file, the watcher and the store; one's own Save is no reason, two replacements in a row, the user's edits are not overwritten and Save conflicts, deletion and return). Stability: four runs in a row. Checked by mutations: a single look without waiting, ignoring Keep Mine, a reload with unsaved edits, forgetting "OK", dismissing "reloaded", swallowing the error "the user typed", no re-arming after a file replacement, no noise filter, cancellation does not cancel.

**A fix after the review.** If during the reading of the file the document moved to another name (Save As), the version does not change, and the text read from someone else's file reached `precondition(file.path == path)`. `ReloadDocumentUseCase` now compares the path after the read, before the text is edited, and throws `DocumentError.pathChanged`; the monitor silently drops such a reload (the watching has already been moved by the save), and the Reload button shows a message.

**Known limits.**
- Watching on network volumes and in iCloud was not checked: kernel events there may not arrive; Save still compares the revision.
- One look costs a read of the whole file (SHA-256) when the metadata changed; for a 100 MB file that is ≈ 0.3 s in the background at every real change.
- A rename of the file by another program is shown as "deleted or moved": watching a file by identity (where it went) is not done.
- Two copies of the application on one file see each other's edits as external.
- The live window, the bar's buttons (Undo, Reload, Keep Mine, Save As…) and the combination with other bars were checked only by component tests.

## ADR-018: Saving without stopping the window (TK-011, the tail)

**Status:** implemented; not checked by hand in a live window ([manual acceptance](10_MANUAL_ACCEPTANCE.md), section H). Data: [ADR-018-capture.json](benchmarks/ADR-018-capture.json).

**The problem.** Save and the recovery checkpoint took a copy of the text with one synchronous `snapshot()` on the main thread: 27.8 ms at 10 MB, 306 ms at 100 MB ([TK-011](benchmarks/TK-011-results.md) called this "a candidate for a separate task"). The window did not respond to input all that time.

**What was done.**
- `DocumentSession.capture(...)` (`IDEApplication`). A document up to 1,000,000 UTF-16 units is copied at once (≈ 1 ms). A larger one is copied **in pieces of 262,144** UTF-16 units, between the pieces the main thread is given back (`Task.yield`), and the resulting `String` is built **in the background**. Edits made during the copying are not lost and do not break consistency: a subscription applies each edit to the part already copied (inside it — by replacement, one that crosses the boundary — by cutting the copy back to the start of the edit, after it — nothing: the next piece reads the live text). The copy is always equal to the beginning of the live text.
- The slice is atomic: **the version, path, encoding and disk revision** are taken at one instant, when the copy is complete and IME holds no marked text; after it, until the write into `DocumentCapture`, there is not a single suspension. If marked text is alive, the capture waits for the end of the composition (an explicit Save asks IME to finish), edits during that time are accounted for. A change of the text bypassing the session (the session learns about it when asked for the text, as a replacement of everything) resets the copy, and it is read again; on any divergence of length the copy is reset as well.
- The semantics of Save did not change: the text of the capture's version is written; if the user typed during the copying, the document stays modified (`savedVersion` ≠ `version`), as before when typing during the write.
- `SaveDocumentUseCase` and `RecoveryCoordinator` take the text through `capture`. The 16 MB recovery limit stays (now by the size of the record, not by stopping the window).

**Numbers** (one machine, one process, three captures in a row; the pause = the longest interval in which nothing else could run on the main thread):

| Size | Before (synchronous) | Now: the longest pause | Now: all the work |
|---|---|---|---|
| 10 MB | 27.8 ms | 0.1–0.3 ms (the first capture 3.5 ms) | 21 ms (the first 413 ms) |
| 100 MB | 306 ms | 0.11–0.32 ms (the first capture 20–27 ms) | 205–209 ms (the first 277–634 ms) |

The first capture of a fresh process is slower and with a pause of up to 27 ms: cold memory on a machine with 8 GB (peak 1.2 GB at 100 MB); in steady state the pause is 0.1–0.3 ms. The "before" 306 ms was the pause entirely.

**Checks.** 13 tests: equality to the text, the version and revision of the slice instant, giving the main thread back between pieces, an edit before / after / across the boundary of the copied part, 12 rounds of random edits during the copying (the capture equals the text of its version), marked text, a request to finish the composition, cancellation, a change bypassing the session, a small document without giving the thread back, saving a large document with typing during the copying. Checked by mutations: edits are not applied to the copy, marked text is ignored, a crossing edit is ignored (the process loops), the comparison bypassing the session (two independent protections: disabling either one is not caught, disabling both is).

**A fix after the review.** The copied pieces are cut where the slice ended or an edit passed, that is, they can split a surrogate pair; each piece was decoded separately, and `😀` at the boundary turned into `��` (in Save and in recovery). Now when the string is assembled the first half of a pair is carried into the next piece; a piece of the copy equals the slice size (`CapturePolicy.sliceUnits`), so tests with small slices check the boundaries as densely as real ones.

**Known limits.**
- The pause was measured by a main-actor ticker, not by run-loop events and not in a live window; typing during the copying itself was not measured.
- Memory: during the capture a UTF-16 copy (200 MB for 100 MB of text) plus the resulting `String` (100 MB).
- Typing during the copying of 100 MB pays at each keystroke the application of the edit to the copy (O(piece)); not measured.
- If edits come faster than the copy can catch up (an edit at the very start every few pieces, replacing the start), the capture may reread; in practice such edits cut the copy back only to the place of the edit.

## ADR-019: Support for Xcode projects (TK-009)

**Status:** accepted by the user (2026-10-10); there is no implementation. Data: [compatibility matrix](11_COMPATIBILITY_MATRIX.md), raw answers in `Tools/CompatibilityMatrix/results`.

**Context.** SourceKit-LSP without a build server does not understand `.xcodeproj` and `.xcworkspace` (cross-file questions get no answer). Two third-party build servers were studied on Xcode 27.0: `sourcekit-xcode-bsp` (talks to swift-build, early, 0.1.0) and `xcode-build-server` (parses `xcodebuild` logs, mature, Python). Both work, but only after a real build; the first has no choice of scheme and configuration, in the second the configuration and the platform are taken from the log of the build that was performed.

**Decision.**
- **What the user installs:** only SwiftIDE and Xcode. The build server **is part of the SwiftIDE distribution and is launched by the application itself**. A separate installation of Python or of the server is not required; the Python server is shipped **with a compatible runtime inside the application**.
- **The first integration:** `xcode-build-server` with the parsing of the log of a build performed by the IDE itself. `sourcekit-xcode-bsp` stays a **research candidate** until the choice of scheme and configuration is solved (it has none; see the matrix).
- **What we promise.**
  - **SwiftPM is the main supported scenario.**
  - **Xcode projects — experimental support on the verified Xcode 27.0:** diagnostics, completion, hover and jump to definition **after a successful build of the selected scheme, configuration and destination**. Xcode 26 and any other versions are not promised.
  - Before calling support for Xcode projects support, the integration is checked on real projects (the first slice on small fixtures does not replace this).
- **A change of settings.** When the user changes the scheme, configuration or destination, or the project changed, the semantics of the Xcode project is **marked stale until a new build**: the interface says so ("Build to refresh code intelligence") and does not pass the old flags off as current. Editing stays local.
- **The user's files are not changed.** Neither `.xcodeproj`, nor schemes, nor `defaultConfigurationName`; `buildServer.json` and the parsed flags (`.compile`) live outside the user's project, in the IDE's data directory.
- **Build in the IDE** runs `xcodebuild` with the selected scheme, configuration and destination, writes a full log and passes it on for parsing; the result of the parsing is tied to this triple.

**What this follows from** (measured, [matrix](11_COMPATIBILITY_MATRIX.md)): on the fixtures `xcode-build-server` passed macOS, the iOS simulator, a workspace of two projects with a local package and a generated file, paths with spaces and through a symlink; peak memory 35 MB, first diagnostic ≈ 2 s; the Debug flags come from the log of a Debug build. The weak spot: without a fresh full log it knows nothing, and after a project edit it relies on the flags of neighbouring files; the "stale until a new build" rule answers this.

**What is still not checked and must be done before the promise.**
- **The embedded Python.** Not measured: the size, signing and notarization of the shipped runtime, hardened runtime, compatibility with the Python version the server was checked on (3.9.6 from Xcode), running inside a sandbox, if there is one. Licences: `xcode-build-server` — MIT, Python — PSF; the notices are added to `THIRD_PARTY_NOTICES.md` when it is included in the distribution (nothing is embedded now).
- **Real projects and Xcode 26**: ObjC/mixed targets, binary dependencies, macros, test targets, several schemes, extensions, a real device.
- **The `kind: xcode` mode** (watches logs built by Xcode itself) and the behaviour with simultaneous builds from Xcode and from the IDE.
- **Log parsing**: the server depends on the format of `xcodebuild`'s output; a format change in a new Xcode version breaks the parsing. A check at every Xcode change and a clear error instead of silently empty semantics are needed.
- **Support of the server**: a third-party author, last commit January 2026. By including it in the distribution we take on the fixes; a fork or patches are fixed in the repository.

**The research candidate (`sourcekit-xcode-bsp`).** We return to it if the choice of scheme and configuration is solved without editing the user's projects (an upstream patch or our own layer). What has been found for this: a new file in 6 s and a project change on the fly without a rebuild; but the modules of neighbouring targets require a real build into its root, a `/private/...` symlink in the path breaks it, the versions of three dependencies float (`main`), the build takes 5 minutes and 1.3 GB.

## ADR-020: Ordered synchronization with SourceKit (TK-010)

**Status:** implemented as the `LanguageInfrastructure` module; completion is connected to the window ([ADR-022](#adr-022-swift-completion-in-the-window-tk-014)), there is no display of diagnostics and hover. Checked on a fake server and on the real `sourcekit-lsp` from Xcode 27.0 on a SwiftPM fixture. Data: [measurement](benchmarks/TK-010-main-thread-cost.json).

**The task.** A completion requested right after typing must refer to the text that was just typed, not to what the server saw earlier. The contract from [04_ENGINE_AND_WORKFLOWS.md](04_ENGINE_AND_WORKFLOWS.md): one ordered queue per connection, nothing is lost, stale answers are dropped, a server failure does not break the editor.

**What was done.**
- **One write queue per connection** (`LanguageServerConnection`). A message is put into the queue synchronously, on the calling thread, and that is the order. A completion request made after an edit ends up in the queue after its `didChange`. A separate `Task` or an actor call per message does not guarantee this: two tasks started in a row may run in any order. The JSON is encoded by the writer, not by the main thread.
- **Edits as ranges** (`OrderedDocumentSync`). `DocumentChangeSet` already gives the edits in descending position order in source coordinates, so they go into `didChange` in that order, and each range is valid in the text left by the previous ones. Positions are computed by a copy of the line index that is updated in the same call as the sending. The encoding is UTF-16, lines by LF, CR LF and CR.
- **The only place with no address in the protocol:** the position between the CR and LF of one `\r\n`. An edit that begins or ends there (for example, deletes only the LF) is sent extended over the whole terminator, and the character taken is returned in the replacement text. Without it the server received a deletion of both characters; this was found by a check on random edits, not by a review.
- **Opening.** The text is taken by `DocumentSession.capture` (in pieces, ADR-018), the line index is built in the background, edits during that time are buffered and go after `didOpen`, in order. After Save As the old address is closed and a new one is opened.
- **Lag.** If there are more than 500 messages in the queue, the continuity of versions is broken or the index length diverges from the document length, the missed edits are replaced by one `didChange` with the full text, which is built **at the moment of writing** and therefore contains everything typed by then. After that, ranges again.
- **Restart** (`SourceKitLanguageService`). When the server exits: the generation grows, waiting requests fail as "server restarted", answers and messages of the old server are dropped, a new one is started with delays of 0.5 / 1 / 2 / 4 / 8 s. A series of quick crashes increases the delay and ends in the `failed` state (the editor keeps working); a server that has worked for a minute starts from the first delay. After `initialize`, `didOpen` is sent to the documents again from the current text; until the answer to `initialize` the server knows of no document.
- **Completion.** A request is not sent during marked text; the context (document version, caret, server generation, composition) is checked again at the answer, and a stale answer is returned as `stale` with a reason and not shown. Cancelling the task sends `$/cancelRequest`.
- **Diagnostics.** **SourceKit-LSP from Xcode 27.0 does not send `version` in `publishDiagnostics`**, even when the client declared `versionSupport` (checked on a raw answer). We do not invent a version from the time of receipt: a report without a version is "unverified" (`unverified`) while the text has not changed, and "stale" (`stale`) after any edit; with a version (a server of another version) it is `current` only for the document's version.

**Checks.** 56 tests: the connection (the order with a slow writer, answers out of order, receiving an answer early, an error, reading piece by piece, answering a server request, closing, cancellation, a deferred message), positions (UTF-16, terminators, a round trip on random text), synchronization (**a server model that applies what was sent literally and is compared with the document's text**: 600 random edits with mixed line endings and surrogate pairs, edits during the copying and between the copy and the open, a quiet edit bypassing the session, lag, Save As, closing, boundary edits inside CR LF, reopening on a new server), the service (the start order, completion, five kinds of staleness, cancellation, restart, prolonged crashes, diagnostics) and four tests on the real `sourcekit-lsp`: completion right after the receiver changed from `Greeter` to `Int`; 150 unambiguous edits in a row without a resync; a killed and restarted server; diagnostics without a version.
Mutations: 25 breakages of the code, all caught (two tests "catch" by hanging, not by failing: a lost answer on closing and waiting for an incomplete header). The survivors of the first round (the continuity check, the loss of edits between the copy and the open, the length check, an answer of the old server) led to new tests. The tests themselves found two errors in the code: edits inside CR LF and a superfluous resync when replaying buffered edits.

**The cost on the main thread** (a debug build, a fake server, one machine): opening 8 MB holds the main thread for up to 0.26 ms (before moving the line index to the background it was 73.8 ms); an edit with synchronization connected 0.13 ms at 1 MB and 0.31 ms at 8 MB.

**Limits (not done).**
- There is no connection to the window, a completion menu, hover, definition, formatting; of the server's capabilities `didOpen`/`didChange`/`didClose`, completion and diagnostics are used.
- No `workspace/didChangeWatchedFiles` (new files on disk are not announced to the server), `didSave`, capability negotiation (completion and diagnostics are assumed to exist), `completionItem/resolve`.
- Non-Swift and larger than 8 MB of UTF-16 are not given to the server. A document without a file is given under a virtual address (ADR-022).
- There is no request timeout: a server that stays silent holds the wait until the task is cancelled.
- One server per root. Xcode projects through BSP (ADR-019) are not included: the server itself looks for `buildServer.json` in the root.
- The integration tests are tied to Xcode 27.0 and the fixture `Fixtures/SwiftPMPackage`; they do not run without the tool. The completion response time was not measured.
- The live window, typing with IME and a real project were not checked.

## ADR-021: Support for the languages of a mixed Swift project

**Status:** accepted as a direction and a contract on 2026-10-10; implementation is still to come. Highlighting and the TK-010 synchronization currently admit only Swift. Accepting the ADR does not extend the verified compatibility matrix.

**Context.** A Swift project may contain C, C++, Objective-C and Objective-C++ sources and headers. Working with them needs both local highlighting and language features with correct build settings. The `.h` extension does not determine the language unambiguously.

**Decision.**

- Support these languages in stages: Swift completion in the window (TK-014) → a shared document language (TK-015) → highlighting of the other languages (TK-016) → language features of mixed projects (TK-017). Design the language contract already when the Swift UI is connected.
- Determine the document language once for highlighting, LSP and commands: a manual choice → the context of the selected target → the extension. A `.h` without a context gets provisional C highlighting with the possibility of a manual change; this is not a guarantee of LSP settings.
- The language identifier belongs to Domain, the effective choice and its revision to Application/the document session; grammars/queries to SyntaxInfrastructure, the protocol mapping to LanguageInfrastructure, the build settings to the project adapters. Changing the language does not change the text/version/Undo, but invalidates the previous results and reopens the LSP document when `languageId` changes.
- Highlighting works locally through Tree-sitter, without LSP and a build; for Objective-C++ the mixed syntax is checked separately. The versions of the dependencies and the licences are fixed when they are connected.
- For the language features, first check the existing SourceKit-LSP with `clangd`; do not introduce separate processes/adapters per language without the results of this check. Upstream declares support for Swift and the C family of languages, SwiftPM and a compilation database. [SourceKit-LSP](https://github.com/swiftlang/sourcekit-lsp)
- Obtain include paths, defines, SDK/target, language standards, module maps and interoperability from the build context. One project context uses a shared service; a change of settings invalidates old requests/diagnostics. [Compile commands](https://clangd.llvm.org/design/compile-commands)
- An already selected workspace takes priority. The nearest `Package.swift` is used for a single SwiftPM file; Xcode/BSP follows ADR-019; `compile_commands.json` is checked in a separate slice. Without a project the file's directory is a fallback root, project features are not promised.

**Consequences.** Highlighting and LSP are accepted separately for each language/context. An unknown language and a server failure leave the text editable. Old results do not pass on a language change even without a text edit. The additional scope of M2/M3 requires a separate estimate; it is not automatically included in the earlier alpha timeline.

**Check.** SwiftPM Swift+C and Swift+C++, Xcode Swift+ObjC and ObjC++, a C/C++ compilation database, ambiguous headers and files without a project. For each language check unsaved edits, completion/diagnostics/hover/definition, the target settings, restart, Undo/IME and measure the latencies. Mark cross-language jumps and generated headers separately; do not count the Swift results of TK-009/TK-010 for the other languages. The detailed plan: [12_MIXED_LANGUAGE_SUPPORT.md](12_MIXED_LANGUAGE_SUPPORT.md).

**The condition for revisiting.** If the chosen toolchain/BSP does not pass correct settings for a specific language or SourceKit-LSP does not provide the needed functions, record the limitations and check a separate `clangd` adapter on the same fixture before changing the process scheme.

## Verified upstream details

TextKit 2-backed views use the modern layout manager; reading the legacy layoutManager can switch a view to TextKit 1. The implemented factory explicitly chooses TK2; the compatibility monitor listens to the switch notifications. [Apple WWDC22](https://developer.apple.com/videos/play/wwdc2022/10090/).

SourceKit-LSP is available in the Swift/Xcode toolchains. The background indexing documentation states it is on by default in Swift 6.1+; the behaviour of the chosen toolchain/BSP is checked by fixtures. [SourceKit-LSP](https://github.com/swiftlang/sourcekit-lsp), [Indexing](https://github.com/swiftlang/sourcekit-lsp/blob/main/Documentation/Enable%20Experimental%20Background%20Indexing.md).

The candidate sourcekit-xcode-bsp is marked by upstream as early-stage; the requirements and setup are fixed in M0. Its init writes buildServer.json: that is an explicit project setting. [BSP repository](https://github.com/slime-studio/sourcekit-xcode-bsp).

## Open decisions

| Question | Experiment | Stage |
|---|---|---|
| Implementing the native contract of ADR-010 | An NSTextView fixture suite and real IME, not only storage edits | M1 |
| Large-file limits and the snapshot/planner cost | p95 input, peak memory, giant lines | M0/M1 |
| The native highlighting strategy | Rendering attributes/visible fragments vs storage attributes | M1/M2 |
| BSP/toolchain compatibility | Real Xcode fixtures, pinned versions | M0: the first slice is done ([matrix](11_COMPATIBILITY_MATRIX.md), ADR-019); real projects and Xcode 26 are ahead |
| Save coordination on network volumes and with an uncoordinated external writer | Scenarios on real volumes; Save As, watcher, recovery | M1 |
| Multiple editor views | Shared text, independent selection/undo behaviour | After the alpha |
| The need for a custom backend | A reproducible failure of the agreed budgets | After measurements |

## ADR template

Context → decision → consequences → check → the condition for revisiting. Mark proposed/accepted/superseded, do not hide old decisions under identical headings.

## ADR-022: Swift completion in the window (TK-014)

**Status:** implemented and connected to the document window; **not checked in a live window** (see "Limits" and section K in the [manual acceptance](10_MANUAL_ACCEPTANCE.md)). Checked by tests, including four end-to-end tests on the real `sourcekit-lsp` from Xcode 27.0.

**The user's decisions.** Its own popup window under the caret; automatic launch after "." and manual by Ctrl+Space; the project root is the nearest `Package.swift` up the path.

**The design.**
- **The port and the state** (`IDEApplication`). `CompletionProviding` and the answer types (`CompletionItem`, `CompletionOutcome`, the reasons of staleness) know nothing of LSP or AppKit. `CompletionController` is a state machine: an automatic launch after a typed ".", if a word or `)]?!}>` precedes it and it is not a number; a manual launch with an anchor at the start of the word under the caret; local filtering of the **full** list by what is typed (a prefix with case, a prefix without case, the start of a later "word" of the name — by humps and underscores; no substring search; `filterText` is used); an **incomplete** list (`isIncomplete`) is requested again while the word grows. It closes on a character outside a word, on any edit other than typing at the end of a word, on a caret shift (checked a move later: the edit and the selection of one keystroke arrive in arbitrary order), on the start of a composition and on an unavailable server. Choosing is one `.languageAction` edit, that is, one Undo step; the range the server named is replaced (`textEdit.range`, for `InsertReplaceEdit` — `replace`), in the document's coordinates at the moment of the answer and with the end shifted by everything typed at the caret after the answer; without a range — the typed word `[anchor, caret)`. An item whose range does not contain the caret (the server named someone else's text or the caret went back before its start) is not offered. The real sourcekit-lsp names the range "from the start of the word to the caret" (`cou|nt` → `countnt`, as it intends); a range beyond the caret and before the start of the word (for example, `?.` instead of `.`) is covered by tests on a fake server. `additionalTextEdits` (auto-import) are not supported. For a call whose signature has no `()`, the caret goes before the closing parenthesis.
- **AppKit.** `EditorInputHooks` (`interceptKey`, `requestCompletion`); `CodeTextView.keyDown` does not hand over keys while the input method has marked text; Ctrl+Space and the system command `complete(_:)` (Esc, F5, Edit ▸ Complete) request completion. `CompletionPopup` is a non-activating child `NSPanel` window with a table (a kind icon, name, detail), under the caret's line or above it if there is no room below; it closes on losing focus, on a resize and on scrolling. `CompletionCoordinator` links the session, the editor and the provider; Esc closes, Return/Enter/Tab accept **only when the list is shown** (otherwise an ordinary line break/tab), the arrows and Page Up/Down move the selection, keys with modifiers are not intercepted.
- **Servers** (`LanguageServices`). One `SourceKitLanguageService` per package root and one shared "scratch" server for files outside a package and Untitled. The root is `PackageRootLocator`. A document without a file gets a virtual address `scratch/Untitled-<8 characters of the id>.swift` (the `untitled:` URI is not supported by the sourcekit-lsp from Xcode 27); Save As moves the session to the right server; when the last document of a package closes, its server is stopped; on quit `terminateAll()`.
- **State and timeout** (the user's decisions: a line in the popup window itself, a 5 s timeout). `CompletionController` keeps a timer per request: after 300 ms without an answer and without an already shown list — "Waiting for SourceKit…"; after 5 s the request is withdrawn (`$/cancelRequest`), an answer that arrives later is dropped, "SourceKit is not responding" is shown. A list already on screen stays at a timeout (it was incomplete but useful) and is not requested again. The reasons why the server cannot be asked are told apart: starting, restarting, the document not yet passed, a failure or no server, nothing found. Only what the user noticed is shown: after "." "no suggestions" and "no server for the document" stay silent (text files where the dot is at the end of a sentence), on Ctrl+Space everything is shown.
- **Resilience to a real server.** In the first moments the server answers with the error −32001 "No language service": the request is repeated up to 4 times with a pause of 150 ms·n. A document right after the server start may not yet have been passed: up to 20×50 ms of waiting for the synchronization.

**What we found on the way.** `untitled:` does not work; a file outside a package root is served; items come with `isIncomplete`, `filterText`, `insertText` without placeholders; −32001 and the race "the document is not synchronized" are visible only on a real server (the fake one did not reproduce them) — both were caught by the end-to-end tests.

**Checks.** 63 tests in `IDEApplicationTests` (the controller 46, keys and agreement with the window 12, text view hooks 5: a real `NSTextView`, key events, marked text) and 12 in `LanguageInfrastructureTests` (servers and routing 8, end-to-end on the real sourcekit-lsp 4). The whole suite: 37 + 74 + 341 + 65 = 517 tests pass (two full runs in a row).
Mutations: 24 breakages in the controller, key handling, hooks, window geometry, retries and server routing. Three survived in the first round: accepting the answer of a stale request (the test did not tell the "old" answer from the "new" one, because the old one did not fit what was typed), keys during marked text (there was no text-view hooks test at all) and a mutant without an address for Untitled (it did not compile; rewritten, caught by an existing test). Tests were written for the first two, after which all 24 were caught.
The end-to-end test "a package file sees the neighbouring files" failed in the full run and under CPU load (six idle loops reproduced it): sourcekit-lsp, while it loads the package, answers with **an empty list with `isIncomplete: true`**, and there was nothing to show until the user typed further. Now an empty "incomplete" answer is asked for again every 0.5 s (up to 20 times), all that time "Waiting for SourceKit…" is shown, then "SourceKit is not ready yet". This is confirmed only on this machine and with this server. Added after the review: the server's ranges (6 tests, 5 breakages caught), statuses and timeout (13 tests, 15 breakages; two survived at first — the cancellation of the request and the token counter at a timeout, because they were duplicated by the "nothing shown" path; the test for the case "the list is already on screen" catches them), the retry after an empty answer (4 tests, 4 breakages caught; the three protections against a deferred retry after closing duplicate each other and cannot be told apart individually — these are equivalent mutants). One mutant is "caught" by a hang or a crash, not by a comparison.

**Limits (not done).**
- **The live window was not seen:** the geometry and look of the menu, the position on scrolling and resizing, the dark theme, the feel of typing, a real input method (only `setMarkedText` in a test was checked). Ctrl+Space may coincide with the system layout switching; Edit ▸ Complete, Esc and F5 work without it.
- No snippet placeholders, documentation window, commit characters, sorting by frequency of use, `completionItem/resolve`.
- The status is shown as a line in the window itself and only for 2 seconds or until the next edit/click; there is no permanent display of the server state (next to the file name).
- The first request in the first second after the window opens may be delayed by the server start and a retry.
- A file outside a package is served in single-file mode (only the SDK, without the neighbouring files).
- The document size limit of 8 MB (UTF-16) from ADR-020; Xcode projects (ADR-019) are not covered by this — there is no `buildServer.json`.
- The time from the keystroke to the menu was not measured.

## ADR-023: Support for Bazel projects

**Status:** accepted as a direction on 2026-10-10; implementation and verification are still to come. ADR-019 keeps the policy of native Xcode projects, ADR-021 the language choice and mixed sources; this ADR adds a separate type of project context.

**Context.** Bazel needs a BSP that obtains compiler settings from Bazel. The current search for the nearest `Package.swift` and the shared single-file service do not provide such a context. Upstream `sourcekit-bazel-bsp` declares a bridge to SourceKit-LSP and language features for Swift/ObjC/C++; SwiftIDE's support is not yet proven by this. [Repository](https://github.com/spotify/sourcekit-bazel-bsp)

**Decision.**

- Introduce a shared project context (TK-018) next to the shared document language TK-015: type/root, targets/config, tools and a revision. An explicitly opened workspace takes priority over discovering a nested SwiftPM package; a change of context invalidates old requests/diagnostics.
- Begin with a spike (TK-019) and experimental language features of an already configured Bazel workspace (TK-020). Reuse the SourceKit-LSP transport, the synchronization and the completion UI; BSP is launched through LSP. The discovery of `.bsp/skbsp.json` and `.sourcekit-lsp/config.json` is checked separately from the legacy `buildServer.json`.
- Allow a project-level choice of SourceKit-LSP and the toolchain/SDK. Check the compatibility of the Xcode distribution and the distribution recommended by upstream; pin the versions after a run. Show preparation/indexing, partial readiness, errors and cancellation; a timeout is mandatory for acceptance.
- Setup from the interface (TK-021) and Bazel Build/Test (TK-022) are separate stages. The parameters and the changes of the setup are visible before applying. Run/debug/simulator and Starlark language support have a separate backlog.

**Consequences.** Setting up the index build, targets, WMO, generated sources and the cache requires checking a real project. The minimum upstream toolchain requirements are not counted as our matrix. The first promise is limited to the verified language features of a specific configuration; mixed languages are accepted under TK-017. The provisional estimates of the spike/integration do not extend the alpha timeline automatically.

**Check.** A small Swift project with a dependency, then mixed targets: completion/hover/definition/diagnostics on unsaved text; cold/warm indexing, a change of BUILD/targets/config, paths and generated files, restart/timeout/cancel and scope termination. The versions, answers and limitations are published in the matrix. Details and estimates: [13_BAZEL_SUPPORT.md](13_BAZEL_SUPPORT.md).

**The condition for revisiting.** With an incompatible BSP/toolchain or an unacceptable cost of indexing, record the limitation, narrow the targets/configuration and repeat the spike before declaring support. A direct BSP client or a replacement of the server are considered by the results of measurements.

## ADR-024: The document language in one place (TK-015)

**Status:** implemented (highlighting, the language server, the menu, the window subtitle); **not checked in a live window** (section M in the [manual acceptance](10_MANUAL_ACCEPTANCE.md)). The default decisions were made without you and await confirmation: the Edit ▸ Language menu, showing the language in the window subtitle, keeping the choice in the application settings by file path.

**The task.** The `.swift` checks were in three places (highlighting, choosing documents for the server, `languageId`). The mixed-language plan ([12](12_MIXED_LANGUAGE_SUPPORT.md)) requires one mechanism and a manual choice that does not touch the text.

**What was done.**
- `IDEDomain.DocumentLanguage`: Swift, C, C++, Objective-C, Objective-C++, Plain Text; the name, the server's `languageId`, parsing a file name (`.h` is C, but *provisionally*; `.C` is C++; the case of the extension does not matter otherwise).
- `IDEApplication.DocumentLanguageSelector` (one per document) decides in the order: a manual choice → the language from the target's build settings (for now a `context` hook, there is no source yet: TK-018) → the file name. The result is `ResolvedLanguage` (language, source, revision). The revision grows only when the **language** changes: a confirmation of what the name already said invalidates nothing. Subscribers receive every change. After saving under a new name the decision is made again; the choice belongs to the document and moves to the new name. `DocumentLanguages` hands everyone the same selector of a document.
- The choice is kept through `LanguageOverrideStore` (in the application — `UserDefaults`, the key is the file's path; Untitled is not stored). It changes neither the file, nor the text, nor the version, nor the dirty state, nor Undo (a test).
- **Highlighting** (`SyntaxColouringController`): `supportedLanguages` (so far only Swift) instead of an extension check; another supported language restarts highlighting from scratch, an unsupported one removes the colours (the reason `languageNotSupported`).
- **The server** (`LanguageServices`): a document goes to the server only if its language is served (Swift); a language change closes the document on the server and opens it again (with the `languageId` from the selector), and if the new language is not served — only closes it; a closed window no longer receives the consequences of a choice. `OrderedDocumentSync.languageID` is an injectable function.
- **The window:** Edit ▸ Language (Automatic and six languages, a mark at the chosen one), the language in the subtitle ("Swift", "C (guess)", "C++ (chosen)"); changing the language closes the completion list.

**Checks.** 12 selector tests (including the ranking of sources, Save As with a choice and without, Untitled, the unchangedness of the text and version), 5 highlighting tests on a language change, 5 server routing tests, 2 application tests (the menu, the store). Mutations: 13 breakages (the priority of sources, carrying the choice over, the revision, the provisional nature of `.h`, the subscriptions to saving and to a language change, restarting highlighting, closing on the old server, the filter of served languages, unsubscribing, storing Untitled), 13 caught. One was caught by a crash (closing on the old server).

**Found on the way.** A full run gave an unstable test: when saving under another name while the language changed at the same time, the server received `didClose` for the old address twice (the synchronization closed the old address itself, and then the closing call went with the previous address). Likewise a `didClose` with an empty address went out for a document that was still being copied and had not been opened on the server. Now `OrderedDocumentSync` remembers that a document is open on the server and closes it once; two tests reproduced both cases before the fix.

**After the review.** `languageServerID` was moved from `IDEDomain` to `LanguageInfrastructure` (as a translation to the protocol identifier, as had been agreed). The subtitle says what the chosen language lacks: "no syntax colours", "no code completion" (`LanguageSupportNote`); choosing a language does not mean that it has highlighting and language features. The key of the choice store is the same canonical path as in the document registry (`DocumentPath.canonical`): a link and its target have one choice (a test). Migration: when workspace settings appear, the choice is moved there from `UserDefaults` once, the key stays the canonical path relative to the root. With TK-018 a **revision of the project context** will be added to the language revision: a change of compiler flags must discard results even when the language is unchanged (there is none now because the document has no source of flags).

**Limits (not done).**
- Highlighting exists for C, C++ and Objective-C (ADR-025), Objective-C++ has none; there are no servers for them (TK-017). The language and the source are shown honestly, but "C (guess)" does not prove correct build flags.
- The language from the target's settings is not connected (a hook without a source, TK-018); a mismatch between the manual choice and the settings is not shown.
- The choice is kept by path in the application settings, not in the workspace settings (there is no workspace yet); a rename of the file outside the application loses the choice.
- Old results on a language change are dropped by the consumers (highlighting restarts, the document is reopened on the server, the list closes); an answer to a request that had already gone to the server at the moment of the change is cut off by the list being closed and the document no longer being on the server — there is no separate language generation in completion requests.
- The server's `languageId`: the Swift server receives only `swift`; the address for Untitled hard-codes the ending `.swift`.

## ADR-025: Highlighting of C, C++ and Objective-C (TK-016)

**Status:** implemented for C, C++ and Objective-C; **Objective-C++ is not supported**; not checked in a live window (section N in the [manual acceptance](10_MANUAL_ACCEPTANCE.md)). Downloading the grammars was permitted by the user on 2026-10-10.

**What was done.**
- Three Tree-sitter grammars pinned to exact versions in `Packages/IDE/Package.swift`: `tree-sitter-c` 0.24.2, `tree-sitter-cpp` 0.23.4, `tree-sitter-objc` 3.0.2 (all MIT; notices in [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md)). The runtime is the same (0.25.10).
- `TreeSitterHighlighter(language:)`: the grammar and the queries are chosen by `DocumentLanguage`; for the others (`objectiveCPP`, `plainText`) the constructor refuses (`unsupportedLanguage`). `TreeSitterHighlighter.supportedLanguages` is the only list; the window hands it to `SyntaxColouringController`.
- The queries `c-`, `cpp-`, `objc-highlights.scm` in `SyntaxInfrastructure/Resources` are **generated** by the script [Tools/Grammars/generate_queries.py](../Tools/Grammars/generate_queries.py) from the `node-types.json` of the pinned grammars (every keyword, preprocessor directive and operator of the grammar is covered) plus hand-written templates for types, calls, parameters, macros, strings and Objective-C messages. The grammars' out-of-the-box queries are sparse (no `goto`, `register`, `@` words and so on), hence our own. The files are committed; when a grammar's version changes the script is run again.
- **An unterminated `/*`.** In Swift it is an operator node; in the C-family grammars it is a parse error with no node of its own. The rule: a `/*` that has no comment, string or `#include` path around it opens a comment to the end of the file (that is how the compiler reads it). A `//` comment and a string with `/*` inside open nothing. Checked in three languages, on typing and closing.
- The menu and the subtitle: for C, C++, Objective-C the "no syntax colours" is gone, for Objective-C++ it stayed.

**Checks.** 9 tests: what is present in each language (keywords, types, calls, parameters, macros, strings, escapes, numbers, labels, properties, Objective-C messages, `this`, `nullptr`, C++ raw strings), three kinds of `/*`, typing and closing a comment, real SDK headers (`sys/stat.h`, `c++/v1/__algorithm/sort.h`, `NSArray.h`: the ranges do not overlap and lie within the text, more than a tenth is covered by colours, the time is under 10 s). Mutations: 12 breakages of the queries and the comment rule, 11 caught; one survivor (`string_literal` in the list of containers) is equivalent — `string_content` covers the same cases.

**Measured on the Xcode 27.0 SDK (the share of parsing with errors, one run).** C: `sys/stat.h` 13%, `sys/socket.h` 6%; C++: `sort.h` 3% (libc++ macros); Objective-C: `NSArray.h` 5%, `NSDictionary.h` 9%, `NSObject.h` 0.4%, **`NSString.h` 97%, `NSURL.h` 100%**. The cause in the last two is `typedef NS_OPTIONS(...) { ... }` and similar macros around enumerations: the grammar sees one big error, and Tree-sitter returns what it could match inside it: comments and keywords are coloured, types and calls are not.

**Objective-C++ is not supported.** A ten-line sample (`std::vector<int>` in a method signature, `for (auto x : v)`, templates) gives errors: C — 25, C++ — 19, Objective-C — 10. No grammar reads the mixture without errors, and the plan forbids taking C++ as proof of Objective-C++. `.mm` stays without colours; the user can manually choose Objective-C or C++ (Edit ▸ Language) and get approximate highlighting, the subtitle honestly says "(chosen)".

**Limits (not done).**
- Objective-C++ and the macros of Apple headers (see above); the preprocessor is not expanded: the active branches of `#if` are not computed.
- No semantics: all `ALL_CAPS` identifiers are constants, a name in a call is a function regardless of what it really is.
- No layout by `.h` context: `.h` is C (provisionally, ADR-024); a C++ header has to be chosen by hand or wait for TK-018.
- Performance was checked only on files up to 135 KB; the large-file policy is shared (5 MB), a test at 1–5 MB for the C family was not done.
- There are no language features (completion, hover) for these languages: TK-017.

## ADR-026: The C family on SourceKit-LSP, first slice of TK-017

**Status:** the first slice is implemented — **completion** for C, C++, Objective-C (and Objective-C++ at the routing level) in a SwiftPM package and for documents without a file, plus Swift completion that sees the package's C/Objective-C targets. The rest of TK-017 (diagnostics, hover, definition, compilation database, Xcode, Bazel) is **not done**. Not checked in a live window (section O in the [manual acceptance](10_MANUAL_ACCEPTANCE.md)). The data was obtained on SourceKit-LSP and clangd from Xcode 27.0.

**What was done.**
- The same `SourceKitLanguageService` serves the C family: SourceKit-LSP itself passes such files to its clangd. `LanguageServices.servedLanguages` is extended to Swift, C, C++, Objective-C, Objective-C++; `languageId` is taken from the document's chosen language (ADR-024): `c`, `cpp`, `objective-c`, `objective-cpp`. A language change closes the document and opens it again with another `languageId`; plain text does not go to the server.
- A document without a file gets a stand-in file with the extension of its language (`Untitled-<id>.c`, `.cpp`, `.m`, `.mm`): the server determines the language by the name.
- Parsing clangd's answer: the label comes with a leading space or "•" (a sign of the source, not text), without `textEdit` the insert text is the name; such labels are shown and inserted without the sign.
- The fixture [`Fixtures/SwiftPMMixed`](../Fixtures/SwiftPMMixed): targets in C (`CLib` with a public header), C++ (`CxxLib`), Objective-C (`ObjCLib`) and Swift (`App`, calls C and Objective-C). It builds and runs (`swift build`).

**What was measured on a real server (7 end-to-end tests, three runs in a row, ≈ 57 s per suite together with the build).**
- C: in `clib.c` after `clib_` — `clib_add`, `clib_length`, `clib_point`; after `p.` — exactly `x`, `y`. C++: the members of the class `cxxlib::Greeter` after `g.`. Objective-C: the message `[self gre` inside `@implementation` — `greetingForTimes…`. Swift in `main.swift`: the functions of the C target (`clib_add(left: Int32, right: Int32)`) and the methods of the Objective-C class (`greeting(forTimes: Int)`). A document without a file, chosen as C: the struct's members.
- **A package build is needed.** A copy of the fixture without a build: the target's headers are not found, a type from a header is unknown (the parameter `clib_point` turns into `int`), members are not suggested (the test `cFamilyWithoutABuildDoesNotKnowThePackagesHeaders` fixes this as a fact about the server). After `swift build` the flags arrive. A package's Swift files get by without a build (as in TK-009).
- **A package in the system temporary folder gets no flags**, neither after a build nor after waiting up to 60 s, even with symlinks resolved (`/private/var/folders/…`); the same package in `~/Library/Caches` or in `Packages/IDE/.build` works. The cause was not found. For the user: a project in `/tmp` and `$TMPDIR` will not get the language features of the C family. The tests keep the copy in `Packages/IDE/.build`.
- **The first answers after opening a file may come without the project's flags** (the first answer in 0.1 s with a global list, the right one in ≈2 s). The tests therefore repeat the request until the expected item appears. For the window this means that in the first seconds the list may be wrong; version control of the project context (TK-018) must cut this off.
- Labels and kinds in clangd are inconsistent: sometimes `clib_add`, sometimes `clib_add(int left, int right)`; for types the kind is often not given (`other`).

**Checks.** `LanguageInfrastructureTests` now has 92 tests: 7 end-to-end on a real server (a separate suite, ≈ 1 min, with the fixture build) and 4 new/replaced tests of routing, the stand-in name and label parsing. Mutations: 5 breakages in routing and parsing, all caught.

**Limits (not done).**
- No diagnostics, hover, definition, formatting for the C family (and for Swift) in the window; no `compile_commands.json`, Xcode/BSP, Bazel for the C family; Swift/C++ interoperability was not checked.
- Objective-C++ is routed to the server, but was not checked by a real server (there is no `.mm` in the fixture).
- `additionalTextEdits` (inserting `#include` for symbols from the index) are not applied: accepting such an item inserts the name without the directive. Items from the index are marked "•" and shown without distinction.
- The build on which the flags depend is not run by the application itself: for now it is the user's action (Build will appear with TK-018/022).
- The time to a correct list, the behaviour on a change of flags and with several targets containing one file were not measured.

## ADR-027: Symbol description, jump to definition and diagnostics in the window (TK-017, second slice)

**Status:** implemented for Swift and the C family on SourceKit-LSP / clangd of Xcode 27.0 (ADR-026); checked by tests, including end-to-end ones on a real server and through a real window; **not checked in a live window** (section P in the [manual acceptance](10_MANUAL_ACCEPTANCE.md)).

**The user's decisions.** Diagnostics — a wavy line under the text, a dot in the line-number margin, a counter in the window subtitle. Hover — the pointer's dwell over a word and ⌃⇧Space at the caret. The jump — ⌘-click and ⌃⌘J; another file opens in its own window at the right line; system and SDK files are read-only. After the review: several definitions — a chooser list (one — at once), "Back" (⌃⌘←) returns to the place the jump started from.

**What was done.**
- **Requests to the server.** The shared part of a request "about a place in the document" was extracted from completion (`positionRequest`): waiting for the document's synchronization, queuing behind the edits already made, a retry on "No language service", rejection if the text, the place, the server changed or a composition is going on. `hover` and `definition` are built on it. Hover: `MarkupContent`, `MarkedString` and their lists are reduced to plain text (fences and emphasis are removed, the words stay), the range into offsets. Definition: `Location`, a list, `LocationLink`; addresses that are not files are dropped; a place in the document itself gets an offset, in another file a line and a position in the line.
- **Diagnostics.** `LanguageServices` translates the server's report into offsets (`DocumentDiagnostics`) at the moment it arrives, if the document is in agreement with the server and the report does not name an old version, keeps the last one and informs the subscribers; a document leaving the server clears it. `DiagnosticsController` moves the marks along with the edits (a mark over edited text grows and shrinks, the text at its edges does not become part of it, typing in front of a mark shifts it) and marks them "stale" (paler) until the next report; a gap in versions removes the marks. It also gives the worst severity by line and the list of problems at a point.
- **Hover.** `HoverController`: the pointer on a word for 0.5 s → a request at the start of the word; another word, leaving the text, an edit, a composition, a click, a key, scrolling, the window losing focus take the description away; inside the shown text the description stays. The problems at a point are shown at once and the server's description is added below. By key — at once and with a word if there is nothing to say ("No quick help here", the reason of unavailability); by pointer — silently.
- **The jump.** `DefinitionController`: one place (duplicates removed) — straight there; several — a pop-up menu "file:line — folder" under the place, the choice moves there; "No definition found"; the reason of unavailability; a newer jump replaces an old one, a stale answer is silently dropped. Before every jump the window tells the application the place it is leaving (`NavigationHistory`, at most 100, an identical one in a row once); Edit ▸ Go Back (⌃⌘←) opens the last one and forgets it.
- **The window.** `HoverPopup` (a small window, takes neither keyboard nor pointer), `DiagnosticsPresenter`, the dots in `LineNumberRulerView`, `LanguageFeaturesCoordinator`; text view hooks (`pointerMoved`, `commandClick`, `requestHover`, `interactionBegan`) and `characterOffset(atViewPoint:)`. The menus Edit ▸ Quick Help, Edit ▸ Jump to Definition. The application opens a file at the needed line through the shared document-opening path.

**What we found on the way.**
- **Underlines through TextKit 2 rendering attributes are not drawn** (checked on a picture of the window: a red text colour gives 136 red points, an underline — 0, including a thick one and with `NSNumber`). So the lines are drawn by a transparent view over the text view: it takes no clicks, draws only what falls into the rectangle being redrawn, takes the geometry from `enumerateTextSegments`.
- **The definition of an SDK symbol** (`print`) is handed out by the server as a `.swiftinterface` file in a temporary folder (`…/T/sourcekit-lsp/GeneratedInterfaces/<id>/Swift.Misc.swiftinterface`). It opens as an ordinary file, is considered a system file (read-only) and is highlighted as Swift (`.swiftinterface` was added to the Swift names).
- The header of a C target is named by the server as in the module map (`CLib.h`), although the file is `clib.h` (the volume is case-insensitive).
- SourceKit-LSP still sends no version with diagnostics. So a mark has three states, and they reach the screen (after the review there were two — the "unverifiedness" was lost in the controller): **verified** (the server named the version, the text has not been edited since; full colour), **unverified** (no version: the report may have been made for text older than the one shown, so the place is shown without a promise of precision; paler colour, 70%) and **stale** (the text was edited after the report arrived: the place is the old one, shifted along with the edits, an approximation; paler still, 40%). A late report without a version after an edit does not look fresh: it is `unverified`, and any next edit makes it `stale` (a test reproduces such a report).
- A problem with no extent (the compiler reports "missing argument" at a position before `)`, length 0) used to be drawn as one character and was almost invisible, and the text of the error was visible only under that character. Now the controller shows such a mark over the word the place is in or after which it stands, and if there is no word — over the text of the line without its indentation and trailing blanks; on an empty line the mark stays as it is. The place is computed again from the current text at every publication, the report itself does not change. The text of the error is shown when the pointer rests on any place of the underlined span and, separately, when it rests on a line with a red dot in the line-number margin (a window under the line, the worst problem first). The window on the margin closes when the pointer leaves, on an edit, on scrolling and on a new report.

**Checks.** 412 `IDEApplicationTests` tests (of them 15 of the diagnostics controller, 16 of the hover/definition controllers, 21 of the coordinator with a real text view and a picture of the window: red points under the word, a dot in the margin, no red through the letters, no interception of clicks), 115 in `LanguageInfrastructureTests` (of them 18 end-to-end on a real server; 11 new — hover, definition in Swift/C/Objective-C/in the same document/in the SDK, Swift and C diagnostics, three through the window; another 9 at the service level with a fake server: parsing hover and definition, rejection, diagnostics through `LanguageServices`), 7 in the application. Mutations: the diagnostics controller 9 (two remained: the version continuity check — a protective one, unreachable through the public interface; `max` for the end — an equivalent), hover/definition 10 (one is equivalent), the AppKit layer 9 (all caught after the added tests).

**Limits (not done).**
- Not checked in a live window: the geometry and look of the lines and of the window, the 0.5 s delay "by feel", behaviour with a real IME, the dark theme, Retina.
- Hover is shown as plain text: Markdown formatting, links and code blocks are not kept; the window is not interactive.
- The menu for choosing definitions is an ordinary `NSMenu.popUp` (blocks until a choice); the tests do not call the showing of the menu itself, the composition of the lines and the path of choosing through a substituted "chooser" were checked. "Back" remembers the places of documents with a file only and does not remember scrolling; the history is shared by the application, not per window.
- No quick fixes (code actions), rename, find references.
- A large number of marks (thousands) and very large files were not measured for drawing speed; the lines are drawn only in the area being redrawn.
- The "read-only" rule is narrow: paths inside `*.sdk/`, `*.xctoolchain/`, `*.platform/Developer/`, `/Library/Developer/CommandLineTools/` and `/Library/Developer/Toolchains/`, `/System/Library/`, `/usr/include/`, `/usr/lib/` and the folder of the server's generated interfaces. A project located in `/Applications` or `/opt` does not fall under it; the files of a package's dependencies (`.build/checkouts`) open for editing.
- Diagnostics, like everything else, depend on the package being built and not lying in the system temporary folder (ADR-026).

## ADR-028: SourceKit-LSP preparation modes, workspace trust and fallback settings (research for TK-018)

**Status:** facts measured on 2026-10-10 on the SourceKit-LSP of Xcode 27.0 (Swift 6.4); **no decision is taken and nothing is implemented**. The proposals at the end are for the TK-018 design and are pending confirmation.

**Method.** The client [`Tools/CompatibilityMatrix/prepare_probe.py`](../Tools/CompatibilityMatrix/prepare_probe.py) starts the toolchain's `sourcekit-lsp`, declares `window.workDoneProgress`, opens a file with an unsaved line appended and asks for completion every 2 s until the expected item appears, printing a timeline of the server's progress, requests and diagnostics. Fixtures: a copy of `Fixtures/SwiftPMPackage` (2 modules, never built) and a folder with two Swift files, a C file and a header. Each cell is one run (a few cold repeats where noted) on one machine (M2, 8 GB); the times are not statistics.

**Facts.**
1. **Background indexing is on by default, and the default preparation mode is `enabled`.** On a cold package the server prepared every target, the test target included, by `swift build --build-system native --package-path <pkg> --scratch-path <pkg>/.build/index-build --disable-index-store --target <T> --experimental-prepare-for-indexing`. The explicit modes differ only in the flags: `enabled` = the default; `build` = no `--experimental-prepare-for-indexing`; `noLazy` adds `--experimental-prepare-for-indexing-no-lazy`. The preparation uses its own `.build/index-build`, not the user's build folder. For the tiny package (3 targets, 2 sources) `.build` grew to about 47 MB in every mode, and the first completion of a member of the other module came 2.6–2.9 s after the process start (one run per mode; this is not a performance comparison).
2. **Configuration keys.** The installed binary contains the keys `backgroundIndexing`, `backgroundPreparationMode` (`build`/`noLazy`/`enabled`), `preparationBatchingStrategy`, `buildSettingsTimeout`, `fallbackBuildSystem`, `workDoneProgressDebounceDuration` and `semanticServiceRestartTimeout`, as in the upstream [configuration documentation](https://github.com/swiftlang/sourcekit-lsp/blob/main/Documentation/Configuration%20File.md) (which describes the main branch). Only `backgroundIndexing` and `backgroundPreparationMode` were exercised here; the others are not verified.
3. **Without background indexing nothing crosses a module until a real build.** With `{"backgroundIndexing": false}` in the initialization options, an unbuilt package gave 20 empty `isIncomplete` completion answers in 40 s and no `.build/index-build`; after a real `swift build` the same request was answered 2.7 s after the start. This agrees with the TK-009 matrix.
4. **Preparation is visible to the client.** With `window.workDoneProgress` declared (our `SourceKitLanguageService` does) the server sends `window/workDoneProgress/create` and `$/progress` with the tokens `indexing.<uuid>` (title "Indexing", reports "n / m", a message "Preparing current file") and `package-reloading.<uuid>` (title "SourceKit-LSP: Reloading Package"); the preparation commands also arrive as `window/logMessage`. SwiftIDE does not read any of these yet: it answers every server request with `null` (`LanguageServerConnection`) and ignores `$/progress`.
5. **A diagnostic made during preparation can be false.** In one of two cold runs the server published `No such module 'Lib'` 2.87 s after the start, just before `Lib` was prepared (the completion that followed already saw `Lib`); the second cold run published no such report. The report names no version, and no later report was captured in the first run, so how long such a report stays on screen is not known.
6. **Workspace-scoped configuration needs the user's trust.** For a root that has `.sourcekit-lsp/` or `.bsp/` the server sends, right after `initialize` (0.04 s), the request `window/showMessageRequest`: "Do you trust the authors of the files in "<name>"? SourceKit-LSP found workspace-scoped configuration (.sourcekit-lsp/ or .bsp/) that may launch external processes or alter how subprocesses are sandboxed. Only trust workspaces from sources you trust." with the actions "Trust Workspace" and "Don't Trust". Answered with `null` (what SwiftIDE does for every server request), the configuration was ignored: with `.sourcekit-lsp/config.json` = `{"backgroundIndexing": false}` indexing still ran and cross-module completion worked. With the option `--bypass-workspace-trust` the same configuration was honoured (indexing off, no answer within 20 s). A plain package without these folders raised no prompt.
7. **Fallback settings (no package, no compilation database).** *Swift:* files are served one by one with the SDK inferred: `s.` on a String gave 190 items including `count` in 0.19 s; a type declared in another file of the same folder is unknown (`Cannot find 'Foo' in scope`, and the member completion on its value stayed empty over repeated requests). *C:* clangd with default flags resolves a header in the file's own folder, but not one in `include/`: it reported `'api.h' file not found` and three follow-on errors that blame the user's code (for example `Call to undeclared function 'api_value'`), which the server does not mark as caused by missing settings.
8. **`compile_flags.txt` is picked up without a prompt, for every language in the folder.** With `-Iinclude` in it the C file's reports fell to the two about the appended test line; but a Swift file in the same root then failed with `Internal SourceKit error: … Loading the standard library failed` (the flags carry no SDK), and recovered when the file was removed. The planned compilation-database slice must not write such a file into a root that holds Swift sources.

**Not measured.** The default of `buildSettingsTimeout` and what exactly happens when it expires; preparation of a large package (time, memory, disk on 8 GB); `preparationBatchingStrategy` and the differences of `noLazy`; whether the false `No such module` report is reproducible; Xcode projects, Bazel/BSP; the behaviour with several packages in one workspace.

**Decisions after the review (2026-10-10).** The proposals of the first version of this note were reviewed; the points below are agreed, except where marked pending.
1. **Four independent groups, not one state.** The server being up, the settings of the current document/target, the background work and the trust are different things: a server can work while the package is being indexed, and the current file can already get right answers.

   | What is tracked | States |
   |---|---|
   | The server | starting, running, restarting, failed |
   | The settings of the current document/target | unknown, loading, prepared, fallback |
   | Background work | reloading the package, preparing/indexing with progress |
   | Trust | undecided, granted, refused |

   The window subtitle shows the one most useful reason ("Preparing package · 2 / 5", "Using fallback settings", "Project configuration disabled"). **"Readiness unknown" is mandatory:** the absence of events proves neither readiness nor the use of fallback settings.
2. **`$/progress` is used to show work, not to declare readiness.** Handle `begin`/`report`/`end`, several tokens at once, and reset them when the server restarts. A progress belongs to one operation; the end of indexing does not prove that every file is ready. `n / m` is shown only when the server sent it; without a total, an indicator without a percentage. Timers serve only timeouts and the message about a hung operation, and expiry never moves the state to "ready". While there is no reliable signal that the project's flags were received, readiness stays unknown: it is not derived from the text of a completion or from the absence of errors.
3. **Diagnostics have two separate characteristics:** whether the report matches the text version (`current`/`unverified`/`stale`, the existing freshness) and whether it was received with confirmed project settings. Even a report with the right version can say `No such module` while a dependency is still being prepared. During the initial preparation the server's underlines and the error counter are hidden and the reason is shown in the subtitle; on fallback settings diagnostics are shown paler and the limitation is stated; finishing the preparation does not turn a stored report into a reliable one (a new report is needed).
4. **Trust: yes, refusal by default.** The decision is kept in the application settings under the canonical workspace root; the repository itself must not be able to declare itself trusted. There are commands to grant and to revoke trust; a server restart does not raise the dialog again. Trust and automatic preparation are separate settings. `--bypass-workspace-trust` is never used automatically.
5. **Confirmed (2026-10-10) — what the trust covers.** For the first slice of TK-018 the trust applies to the **project configuration**, not to the whole folder. A refusal of the SourceKit-LSP request disables only its workspace-scoped configuration; ordinary SwiftPM preparation still runs (fact 6: indexing ran with the configuration ignored; the logs also show the package manifest being evaluated). So the dialog says so plainly. The agreed text (the user's wording, translated; the application's own strings are English): "Allow the project configuration? It may launch external processes and change the parameters of their execution. Declining disables this configuration but does not stop the processing of the manifest and the SwiftPM preparation." The buttons are "Allow configuration" and "Don't allow", **the second is the default**. After a refusal the status reads "Project configuration disabled" instead of "Workspace not trusted". The earlier example "Workspace not trusted" in item 1 is replaced by this wording. A mode for opening an untrusted folder that blocks the execution of project code (BSP, build, preparation, manifest evaluation until consent) is **a separate task, not part of TK-018**.

**Acceptance of TK-018 must include:** two progress operations at once; a restart in the middle of a preparation; a server that sends no progress at all; a refusal of trust, with **both results confirmed explicitly: the configuration is ignored, and ordinary SwiftPM preparation may continue**; reopening a trusted workspace (no new dialog, the stored decision applies); and a `No such module` report that arrives before the preparation finishes (it is hidden and does not come back as a reliable report afterwards).

**Not decided here:** the exact subtitle wording and the placement of the trust commands in the menus (to be shown on the prototype); the setting for automatic preparation (a later project setting).
