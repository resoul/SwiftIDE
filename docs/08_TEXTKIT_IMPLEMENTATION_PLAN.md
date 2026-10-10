# TextKit 2 implementation: the current slice and the next steps

## What is already implemented

In the production package `Packages/IDE`:

- `DocumentEditingBackend` — an Application port with an immutable text read and a synchronous commit.
- `DocumentSession` — version/savedVersion, optimistic validation, subscriptions; it has no mutable text of its own.
- `DocumentEditPlanner` — checks of UTF-16 ranges, surrogate boundaries, overlaps; staging before mutation.
- `TextKitDocumentBackend` — NSTextStorage → NSTextContentStorage → NSTextLayoutManager → NSTextContainer.
- `StringDocumentBackend` — a headless reference/test adapter of the same port.
- `DocumentChangeSet` — one version-tagged batch of programmatic edits in source coordinates.
- The Composition Root chooses the TextKit backend; save receives an independent snapshot.

`Packages/IDE` already has `TextKitEditorFactory`, `EditorHostView` and a compatibility monitor; `Apps/SwiftIDE` creates a window with an NSTextView over the backend's storage graph. Native input, document-scoped undo and the composition bridge (TK-005) are implemented, see the section "TK-005 implementation"; real file open/save is not implemented. The window itself does not confirm the usability and performance of a finished editor.

## 1. Native view factory

TextKitEditorFactory and EditorHostView are implemented (TK-004). Keep the explicit choice of TextKit 2; check for the modern textLayoutManager and listen to the will/didSwitchToNSLayoutManager notifications. Do not read the legacy layoutManager even in debug checks, the gutter or third-party extensions. [Apple on compatibility mode](https://developer.apple.com/videos/play/wwdc2022/10090/).

The view and the backend use **one storage/content graph**. The factory lives in the platform module and does not hand mutable storage to Application. A separate NSTextView.string mirrored with the backend's changes must not be created.

Plain text mode; turn off automatic quote/dash substitution, rich text and spelling behaviour that are unsuitable for code. Input settings change explicitly. Native selection/focus/scroll stay the state of the editor view.

## 2. Extending the transaction bridge

Programmatic v0.1: Session → validated plan → backend commit → version/event.

Native v0.2 (TK-005, implemented): pre-edit capture/validation → native storage transaction → exact committed changes → the session accepts a transaction that has already happened and publishes the version/event. This path **does not call backend.commit again**. Introduce a transaction ID, baseVersion, origin and immutable before/after snapshots; replacements are given in "before" coordinates. The transaction ID is assigned to an operation, not to every delegate callback. A programmatic commit and a native callback use a shared operation context and a single completion point so as not to increase the version twice.

Use `didProcessEditing` for verification and for distinguishing characters from attributes. It does not contain the full original edit log for an arbitrary grouped batch. If an operation does not give exact replacements, compare the immutable before/after snapshots and obtain one correct replacement of the changed range; this is an O(n) fallback with its cost measured. Do not rebuild a ChangeSet from guessed ranges.

Extending the backend interface must be done **before** the native view's mutable storage is opened: the current commit-only port permits only session-controlled programmatic editing. Do not bolt an independent version counter onto the storage delegate.

The policy of refusal and reconciliation:

- In `shouldChangeText` check that editing is available, reentrancy, the validity of the known UTF-16 ranges and the version headroom; programmatic requests additionally check expectedVersion and the whole batch. Reject a manifestly invalid edit **before mutation**. Swift syntax errors are not a reason to refuse input. The native input context normalizes AppKit's special ranges before the application validation; the absence of an exact replacement log does not by itself forbid IME.
- Do not treat `shouldChangeText` as a universal interceptor of arbitrary storage writes. Every storage pass that changed characters is counted by the backend's `editGeneration` counter, and the bridge describes the change by `editedRange` and `changeInLength`. Attribute-only changes and text no-ops do not create a text revision; a repeated callback of the same transaction does not create a second event.
- If an edit that has already happened did not match the plan or had no preflight, accept the backend's actual text: build a correct diff from the last agreed snapshot, increase the version and publish one ChangeSet. When there is no exact journal, a single replacement, including the whole document, is acceptable **in the event**, with no write back into storage. Record a diagnostic fact of the reconciliation; consumers that lost the sequence perform a resync from the current snapshot.
- `didProcessEditing` verifies the result but does not rewrite characters. Completing the transaction/publishing is done at a safe boundary of the native operation after the storage has been processed; until then a snapshot with the new text and the old version must not be handed out, nor the next edit accepted. Do not postpone the reconciliation with an arbitrary `Task` that allows other edits between the capture and the publication. [Apple's limitations for didProcessEditing](https://developer.apple.com/documentation/appkit/nstextstoragedelegate/textstorage(_:didprocessediting:range:changeinlength:)).

Thus the invariant "validation before mutation" applies to managed operations. For an unexpected native mutation that has already happened, the mandatory reconciliation of the session with the backend applies, not a post-factum refusal with a stale version.

## 3. Undo and IME

Use **one NSUndoManager per document** (in Swift — `UndoManager`), owned by the platform `NativeUndoCoordinator`. The adapter returns it through `NSTextViewDelegate.undoManager(for:)`, and the view keeps `allowsUndo = true`. Native typing registers undo by NSTextView's own means; the coordinator does not add a second inverse for the same operation. Programmatic format/replace registers the inverse exactly once in the same manager and gets its own semantic undo group, separate from typing. Application does not receive AppKit types and keeps no parallel stack. [Apple: undoManager(for:)](https://developer.apple.com/documentation/appkit/nstextviewdelegate/undomanager(for:)).

Capture the origin at the start of the operation: `isUndoing` → `.undo`, `isRedoing` → `.redo`; these states take priority over `.typing`/`.composition` and are not determined again after a deferred callback. Undo/redo go through the same transaction bridge. One undo group does not necessarily equal one text revision; every resulting snapshot of a transaction that really changed gets the next version. Undo returns the text, but not the old version number. In the current contract `isDirty = version != savedVersion`: returning to the saved text through undo leaves dirty until the next save. A content-based clean marker is a separate future decision.

**Composition: publish the intermediate changes.** Every completed step that changed characters gets a new version and `origin: .composition`; a cancellation that restores the original text also creates a new version. A change of selection/marked attributes and `unmarkText` without a change of characters do not increase the version. The composition state (begin/update/end) is passed separately from the text ChangeSet through application-level values, so that an end with no text change unblocks the waiting operations.

The authoritative text is always one — the backend's current text, marked text included; the session snapshot corresponds to it. LSP receives the composition revisions too, in the shared ordered queue. In TK-005 do not introduce a second "last confirmed" text for LSP. While there is marked text, do not apply completion/format/language-action edits; after it ends re-check the version/context, and drop stale results.

**Save during composition:** an explicit Save asks the native input bridge to finish the composition in the normal way, waits for the transaction to finish and only then captures the current snapshot N for writing. If it cannot be finished at once, the request stays pending until end/cancel; the UI does not report success before the real write. Autosave is postponed until end/cancel without forcing the input to end. Do not quietly save the old pre-composition snapshot. A Save that has already captured N before new input began may finish and confirms only N, keeping dirty for N+1. The gate is implemented in `SaveDocumentUseCase` (`SaveTrigger.explicit/.autosave`).

Check intermediate marked text, cancellation, repeated replacement, selection inside the marked range, dead keys and unmark. Do not replace the whole text in response to a delegate — it may break the native composition/selection. When it ends without a text change, a composition-state notification and the continuation of the pending save are needed, but not an artificial version bump.

In the alpha there is one writable view per document. Multi-cursor/split need a separate design of shared undo and independent selection; do not enable them as a "ready NSTextView capability".

## 4. Open/save and metadata

Implemented in TK-006, see [ADR-011](07_ARCHITECTURE_DECISIONS.md#adr-011-open-save-and-disk-revisions-for-tk-006). Below is the original statement.

Add a real DocumentFileStore with an expected disk revision and a receipt, a registry for repeated opens, a UTF-8/BOM policy, line endings and a conflict flow. Saving captures snapshot N; a late success does not clear dirty from N+1. Recovery and coordinated writes are checked separately.

The current MemoryDocumentFileStore stays a demo/test adapter. Do not treat it as proof of an atomic filesystem save.

## 5. Presentation and language services

An extension after Swift completion in the window: a single language choice (TK-015), local highlighting of C/C++/Objective-C/Objective-C++ (TK-016), then LSP for mixed projects (TK-017). The existing rendering-only path, versions/Undo/IME and the limits stay the criteria for every grammar. This is a plan, not ready support: [ADR-021](07_ARCHITECTURE_DECISIONS.md#adr-021-support-for-the-languages-of-a-mixed-swift-project), [criteria and fixtures](12_MIXED_LANGUAGE_SUPPORT.md).

The gutter counts logical lines independently of the full layout; visible fragments give the geometry. Start with simple line numbers and diagnostics, without folding.

Update the syntax attrs over bounded ranges and measure invalidation. Rendering-only attributes are possible as a separate strategy; choose after a prototype. Highlighting does not increase the text version and does not clutter undo.

LSP/save/recovery receive separate subscriptions. A synchronous callback only enqueues; per-consumer queues are bounded. LSP keeps the ordering, flushes before completion and resyncs after an overflow/restart. An absolute UTF-16 offset is converted to line/character through the line index of the source snapshot.

## 6. Measurements and exit criteria

Ordinary Swift files, 1/10/100 MB, a giant line, mixed CRLF, emoji/bidi. Measure the whole input → prepare/copy → commit → layout → present pipeline, peak memory, snapshots and undo retention.

100 MB is a stress point; the supported limit is determined by the result. In the current planner full copies are inevitable. A window with a fast first draw does not prove low latency of subsequent edits.

The native prototype is ready when type/paste/undo/redo/format work, IME does not break, the save race is handled, attrs do not change the version, old snapshots are unchanged and there is no unexpected TextKit 1 fallback. Then we connect the language features and the project build.

The order of TK-005: extend the backend port and the shared session transaction finalizer → NativeEditingBridge with preflight, verification and reconciliation → NativeUndoCoordinator → the composition-state/save gate and consumer policies. The automatic fixtures call `insertText`, `setMarkedText`, `unmarkText`, undo/redo on a real NSTextView and check revisions/events; they do not replace manual input through real CJK IME and dead keys. The separate criteria are in [quality checks](06_QUALITY_AND_RISKS.md#tk-005-native-inputundoime).

If TextKit does not pass the agreed budgets, we record a fixture and a profile, try a bounded optimization, then adopt an ADR about a custom backend. Its cost includes a new UI/input/undo bridge and a snapshot/preparation contract.


## TK-005 implementation: what came out and where the contract was refined

Code: `IDEApplication/NativeEditing.swift`, `TextSource.swift`, `DocumentEditPlanner.swift`, `EditRegionAccumulator.swift`, `EditInversion.swift`, `DocumentSession`; `EditorPlatformTextKit/NativeEditingBridge.swift`, `NativeUndoCoordinator.swift`, `CodeTextView.swift`. Tests: `NativeTransactionTests` (headless, a simulated view) and `NativeTextViewTests` (a real NSTextView).

- **One version path.** The backend receives a `NativeEditReceiver` (the session) through `attach(nativeEditReceiver:)`. `DocumentSession` **does not keep** the text: only `version`, the length and `knownGeneration` (ADR-012). `snapshot()` assembles the text from the backend and pairs it with `version`, because the accounting of edits is synchronous; `text` is simply a copy of the backend's text. A programmatic commit publishes by itself; a native callback during a commit is ignored; a repeated delivery of the same commit is ignored by generation; an attribute-only pass and a replacement of a fragment by itself give the effect `unchanged` and create no events.
- **Preflight** (`shouldChangeText`): the view is editable, the session is not publishing or committing, version headroom, ranges within the storage and not cutting a surrogate pair. The origin and the exact replacements are captured at the same time.
- **Accounting of an edit (O(edit)).** The bridge describes the change as one replacement in "before" coordinates: if the preflight knew the edit and the storage agrees with it (the length changed by exactly that much, `editedRange` covers the inserted text) — exact (`isExact`); otherwise the region reported by the storage itself (`editedRange` + `changeInLength`), which may include unchanged characters too (`isReconciled = true`, `reconciliationCount` grows). Compound operations add their passes into `EditRegionAccumulator`. The session checks only the length and the generation: a commit whose length does not agree with the backend or which does not cover all the passes since the last accounting becomes a replacement of the whole document (`isReconciled`), and consumers resync. The whole text is neither read nor compared when accounting for an edit. No write back into the storage is made. An edit during publication is deferred until its end, in order of arrival.
- **The completion boundary** is `NSTextStorage.didProcessEditingNotification` (synchronous, no Task). This is not an exit from `processEditing()`: the notification arrives inside it, before the layout managers are notified. It is allowed to read the state and queue events; do not change characters and do not consider the layout finished.
- **Compound operations.** `NSTextView.unmarkText()` in TextKit 2 deletes and reinserts the marked text internally. The view operations `insertText`/`setMarkedText`/`unmarkText` are folded into one commit (`performCoalesced`), otherwise an unmark without a text change would give two revisions. "Without a change" for unmark is determined by comparing the text of the marked range before and after (O(marked)).
- **Inverse edits** are normalized: inverse edits that touch each other or coincide in position (adjacent deletions) are merged into one, otherwise the batch would be rejected by the validator.
- **The boundary of an undo step and the ownership of groups** (`DocumentUndoManager`). With `groupsByEvent` the run loop holds one implicit group per event, and NSTextView registers typing in it; a nested group is still rolled back together with it. So the split is made **at the moment of the real registration**, not in advance: a programmatic step always gets a fresh group, and typing after it (and after `breakUndoCoalescing()`, which the coordinator calls after a programmatic edit) is separated from it. Groups are not opened in advance, so a step that did not register leaves no empty group. Only groups opened by the system (inside a registration, undo or redo) may be closed. A group opened by the calling code through `beginUndoGrouping()` belongs to it: while it is open, steps simply enter it, and the `begin/end` pairing is not broken. If the accounting disagrees with the real nesting, unknown groups are treated as foreign. A new group after a manual closing of the event group has to be left open: the run loop will close exactly one.
- **A known limitation.** `shouldChangeText` is a promise of a change: AppKit registers its own undo step right inside it (checked on a plain NSTextView). If the calling code got `true` but did not make the edit, a step remains that only AppKit can explain, and executing it may damage the text; it cannot be selectively removed. In this case the bridge leaves neither a pending preflight nor an open group, and the session stays equal to the view's text. A refusal in our preflight (an invalid range, publication, a non-editable view) happens before AppKit's registration and creates no step.
- **Save.** An autosave waiting on a composition does not block an explicit Save: the request joins it and raises it to explicit (it requests the end of the composition); cancelling the autosave does not cancel the Save that joined, which starts afresh. A write in progress still gives `saveInProgress`.
- **`isReconciled`** means "there was no exact journal", not an error: that is how, for example, NSTextView's own undo/redo arrives.
- **Undo.** There is one `UndoManager`; the delegate `undoManager(for:)` gives it to the view. Typing is registered by NSTextView itself, programmatic edits — exactly one inverse (`PreparedDocumentEdit.inverseEdits`) in a separate group. NSTextView's own undo/redo does not call `shouldChangeText`, so it arrives as a reconciliation by diff (`origin` `.undo`/`.redo`, a correct ChangeSet, `isReconciled = true`); the undo/redo of programmatic edits is performed by the coordinator, which passes exact edits.
- **Composition.** `CompositionEvent` `.began/.updated/.ended` goes separately from the text revisions. `unmarkText` without a text change gives `.ended` without a new version. While a composition is active, `apply` throws `DocumentError.compositionInProgress`. An explicit Save calls `requestCompositionEnd()` and waits for `.ended`; autosave only waits; the waiting is cancellable.

Not done: the LSP consumer and queue (TK-010), a real file store (TK-006), the acceptance of save N/N+1 is already covered by existing tests. Not checked automatically: real CJK IME and dead keys, selection inside the marked range during scroll/wrap, undo during an active IME, the absence of duplicates when a composition is ended automatically by a mouse click (if AppKit does not call `unmarkText` on the view, the state will be caught only by `textDidChange`).
