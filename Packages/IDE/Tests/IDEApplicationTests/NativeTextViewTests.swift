import AppKit
import EditorPlatformTextKit
import IDEApplication
import IDEDomain
import IDETestSupport
import Testing

/// Drives a real NSTextView through the same entry points AppKit input methods use.
/// These do not replace manual checks with real CJK input sources and dead keys.
@MainActor
private struct Fixture {
    let editor: TextKitEditor
    let session: DocumentSession
    let log: ChangeLog
    var textView: NSTextView { editor.textView }

    init(_ text: String) {
        editor = TextKitEditorFactory.makeEditor(loadedText: text)
        session = DocumentSession(path: "Main.swift", backend: editor.backend)
        log = ChangeLog()
        let log = log
        session.subscribeToChanges { log.changes.append($0) }
        session.subscribeToComposition { log.composition.append($0) }
    }

    /// Lets the run loop close NSUndoManager's implicit per-event group, as a real event ends.
    func endEvent() {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.001))
    }

    func type(_ string: String, at location: Int, replacing length: Int = 0) {
        textView.insertText(string, replacementRange: NSRange(location: location, length: length))
        endEvent()
    }
}

@MainActor
private final class ChangeLog {
    var changes: [DocumentChangeSet] = []
    var composition: [CompositionEvent] = []
}

@Test @MainActor
func typingAndPastingPublishOneExactRevisionEach() {
    let f = Fixture("let a = 1\n")
    f.type("x", at: 3)
    f.type("PASTED", at: 0, replacing: 3)
    #expect(f.textView.string == "PASTEDx a = 1\n")
    #expect(f.session.text == f.textView.string)
    #expect(f.session.version == 2)
    #expect(f.log.changes.map(\.origin) == [.typing, .typing])
    #expect(f.log.changes.allSatisfy { !$0.isReconciled })
    #expect(f.log.changes[1].edits == [DocumentEdit(range: UTF16TextRange(location: 0, length: 3), replacement: "PASTED")])
    #expect(f.session.isDirty)
    #expect(f.editor.compatibility.isTextKit2)
}

@Test @MainActor
func undoAndRedoOfTypingKeepGrowingVersionsWithUndoRedoOrigin() throws {
    let f = Fixture("abc")
    f.type("X", at: 3)
    let manager = f.editor.undo.undoManager
    #expect(manager.canUndo)

    manager.undo()
    #expect(f.textView.string == "abc")
    #expect(f.session.text == "abc")
    #expect(!manager.canUndo, "no empty leftover undo step")
    #expect(f.session.version == 2)
    #expect(f.log.changes.last?.origin == .undo)

    manager.redo()
    #expect(f.textView.string == "abcX")
    #expect(f.session.version == 3)
    #expect(f.log.changes.last?.origin == .redo)
    #expect(f.log.changes.count == 3)
}

@Test @MainActor
func undoBackToSavedTextStaysDirtyByVersion() async throws {
    let f = Fixture("abc")
    f.type("X", at: 3)
    f.editor.undo.undoManager.undo()
    #expect(f.session.text == "abc")
    #expect(f.session.isDirty)
}

@Test @MainActor
func programmaticAndTypingShareOneHistoryWithoutDoubleRegistration() throws {
    let f = Fixture("abc")
    f.type("X", at: 3)                                  // "abcX"
    try f.session.apply(
        [DocumentEdit(range: UTF16TextRange(location: 0, length: 1), replacement: "AAA")],
        expectedVersion: 1, origin: .formatting
    )                                                   // "AAAbcX"
    f.endEvent()
    #expect(f.textView.string == "AAAbcX")
    let manager = f.editor.undo.undoManager

    manager.undo()                                      // reverts only the programmatic edit
    #expect(f.textView.string == "abcX")
    #expect(f.session.text == "abcX")
    #expect(f.log.changes.last?.origin == .undo)
    #expect(!(f.log.changes.last?.isReconciled ?? true))

    manager.undo()                                      // reverts the typing
    #expect(f.textView.string == "abc")
    #expect(f.log.changes.last?.origin == .undo)

    manager.redo()
    manager.redo()
    #expect(f.textView.string == "AAAbcX")
    #expect(f.session.text == "AAAbcX")
    #expect(f.log.changes.last?.origin == .redo)
    #expect(f.session.version == 6)
    #expect(!manager.canRedo)
}

@Test @MainActor
func newEditAfterUndoDropsRedoBranch() {
    let f = Fixture("abc")
    f.type("X", at: 3)
    f.editor.undo.undoManager.undo()
    #expect(f.editor.undo.undoManager.canRedo)
    f.type("Y", at: 3)
    #expect(!f.editor.undo.undoManager.canRedo)
    #expect(f.session.text == "abcY")
}

@Test @MainActor
func preflightRefusesEditWhilePublishingAndLeavesEverythingUntouched() {
    let f = Fixture("abc")
    var refused = false
    f.session.subscribeToChanges { _ in
        // An observer tries to type into the view in the middle of publication.
        let before = f.textView.string
        f.textView.insertText("Z", replacementRange: NSRange(location: 0, length: 0))
        refused = f.textView.string == before
    }
    f.type("X", at: 3)
    #expect(refused)
    #expect(f.textView.string == "abcX")
    #expect(f.session.version == 1)
}

@Test @MainActor
func nonEditableViewAndInvalidRangesAreRefusedBeforeMutation() {
    let f = Fixture("😀ab")
    let undoDepthBefore = f.editor.undo.undoManager.canUndo
    // Splits the surrogate pair of the emoji.
    #expect(!f.textView.shouldChangeText(in: NSRange(location: 1, length: 0), replacementString: "X"))
    // Beyond the end of the storage.
    #expect(!f.textView.shouldChangeText(in: NSRange(location: 99, length: 1), replacementString: "X"))
    f.textView.isEditable = false
    #expect(!f.textView.shouldChangeText(in: NSRange(location: 0, length: 0), replacementString: "X"))
    #expect(f.session.version == 0)
    #expect(f.textView.string == "😀ab")
    #expect(f.editor.undo.undoManager.canUndo == undoDepthBefore)
}

@Test @MainActor
func attributeChangesAndSelectionCreateNoRevision() throws {
    let f = Fixture("let value = 1\n")
    try f.editor.backend.setForegroundColor(.systemRed, in: NSRange(location: 0, length: 3))
    f.textView.setSelectedRange(NSRange(location: 2, length: 3))
    f.textView.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
    #expect(f.session.version == 0)
    #expect(f.log.changes.isEmpty)
    #expect(!f.session.isDirty)
}

// MARK: Composition

@Test @MainActor
func markedTextStepsPublishCompositionRevisionsAndEndNotifies() {
    let f = Fixture("ab")
    f.textView.setMarkedText("k", selectedRange: NSRange(location: 1, length: 0),
                             replacementRange: NSRange(location: 2, length: 0))
    #expect(f.session.isComposing)
    #expect(f.session.text == "abk")
    f.textView.setMarkedText("ka", selectedRange: NSRange(location: 2, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
    #expect(f.session.text == "abka")
    // Commit by inserting the final text over the marked range.
    f.textView.insertText("か", replacementRange: NSRange(location: NSNotFound, length: 0))
    #expect(!f.session.isComposing)
    #expect(f.textView.string == "abか")
    #expect(f.session.text == "abか")
    #expect(f.session.version == 3)
    #expect(f.log.changes.map(\.origin) == [.composition, .composition, .composition])
    #expect(f.log.composition.first == .began)
    #expect(f.log.composition.last == .ended)
    #expect(f.log.composition.filter { $0 == .began }.count == 1)
    #expect(f.log.composition.filter { $0 == .ended }.count == 1)
}

@Test @MainActor
func unmarkWithoutTextChangeEndsCompositionWithoutRevision() {
    let f = Fixture("ab")
    f.textView.setMarkedText("k", selectedRange: NSRange(location: 1, length: 0),
                             replacementRange: NSRange(location: 2, length: 0))
    let versionDuring = f.session.version
    f.textView.unmarkText()
    #expect(!f.session.isComposing)
    #expect(f.session.version == versionDuring)
    #expect(f.log.composition.last == .ended)
    #expect(f.session.text == "abk")
}

@Test @MainActor
func cancellingCompositionRestoresTextWithNewRevision() {
    let f = Fixture("ab")
    f.textView.setMarkedText("k", selectedRange: NSRange(location: 1, length: 0),
                             replacementRange: NSRange(location: 2, length: 0))
    f.textView.setMarkedText("", selectedRange: NSRange(location: 0, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
    #expect(f.textView.string == "ab")
    #expect(f.session.text == "ab")
    #expect(f.session.version == 2)
    #expect(!f.session.isComposing)
    #expect(f.log.composition.last == .ended)
}

@Test @MainActor
func programmaticEditIsRejectedInsideMarkedTextAndAllowedAfter() throws {
    let f = Fixture("ab")
    f.textView.setMarkedText("k", selectedRange: NSRange(location: 1, length: 0),
                             replacementRange: NSRange(location: 2, length: 0))
    #expect(throws: DocumentError.compositionInProgress) {
        try f.session.replaceText("zzz", expectedVersion: f.session.version)
    }
    #expect(f.textView.string == "abk")
    f.textView.unmarkText()
    try f.session.replaceText("zzz", expectedVersion: f.session.version)
    #expect(f.textView.string == "zzz")
}

@Test @MainActor
func saveDuringCompositionFinishesItAndWritesFinalText() async throws {
    let f = Fixture("ab")
    let store = SpyStore()
    let save = SaveDocumentUseCase(store: store)
    f.textView.setMarkedText("k", selectedRange: NSRange(location: 1, length: 0),
                             replacementRange: NSRange(location: 2, length: 0))
    let receipt = try await save.execute(document: f.session)
    #expect(!f.session.isComposing)
    #expect(await store.texts == ["abk"])
    #expect(receipt.savedVersion == f.session.version)
    #expect(receipt.isCurrent)
}

private actor SpyStore: DocumentFileStore {
    private(set) var texts: [String] = []
    func read(path: String, maximumBytes: Int) async throws -> LoadedFile { throw FileStoreError.notFound }
    func write(_ snapshot: DocumentSnapshot, expecting: SaveExpectation) async throws -> FileRevision {
        texts.append(snapshot.text)
        return .stub(Int64(texts.count))
    }
}

// MARK: Undo regressions

@Test @MainActor
func undoOfAdjacentDeletionsInOneBatchRestoresText() throws {
    let f = Fixture("abcd")
    try f.session.apply([
        DocumentEdit(range: UTF16TextRange(location: 1, length: 1), replacement: ""),
        DocumentEdit(range: UTF16TextRange(location: 2, length: 1), replacement: "")
    ], expectedVersion: 0, origin: .formatting)
    #expect(f.textView.string == "ad")
    f.endEvent()
    let manager = f.editor.undo.undoManager
    manager.undo()
    #expect(f.textView.string == "abcd")
    #expect(f.session.text == "abcd")
    manager.redo()
    #expect(f.textView.string == "ad")
    #expect(f.session.text == "ad")
}

@Test @MainActor
func programmaticEditIsItsOwnUndoStepEvenInTheSameRunLoopPassAsTyping() throws {
    let f = Fixture("abc")
    f.textView.insertText("X", replacementRange: NSRange(location: 3, length: 0))
    // No run-loop turn between the two operations: they share NSUndoManager's implicit group.
    try f.session.apply(
        [DocumentEdit(range: UTF16TextRange(location: 0, length: 1), replacement: "AAA")],
        expectedVersion: 1, origin: .formatting
    )
    #expect(f.textView.string == "AAAbcX")
    // Undo comes from a later user event, after the run loop closed the implicit group.
    f.endEvent()
    let manager = f.editor.undo.undoManager
    manager.undo()
    #expect(f.textView.string == "abcX")
    manager.undo()
    #expect(f.textView.string == "abc")
    #expect(f.session.text == "abc")
    #expect(!manager.canUndo, "no empty leftover undo step")
}

@Test @MainActor
func typingAfterProgrammaticEditInTheSamePassIsSeparateToo() throws {
    let f = Fixture("abc")
    try f.session.apply(
        [DocumentEdit(range: UTF16TextRange(location: 0, length: 1), replacement: "AAA")],
        expectedVersion: 0, origin: .formatting
    )
    f.textView.insertText("X", replacementRange: NSRange(location: 5, length: 0))
    #expect(f.textView.string == "AAAbcX")
    f.endEvent()
    let manager = f.editor.undo.undoManager
    manager.undo()
    #expect(f.textView.string == "AAAbc")
    manager.undo()
    #expect(f.textView.string == "abc")
}

@Test @MainActor
func lonelyProgrammaticEditLeavesExactlyOneUndoStep() throws {
    let f = Fixture("abc")
    try f.session.apply(
        [DocumentEdit(range: UTF16TextRange(location: 0, length: 1), replacement: "Z")],
        expectedVersion: 0, origin: .formatting
    )
    f.endEvent()
    let manager = f.editor.undo.undoManager
    manager.undo()
    #expect(f.textView.string == "abc")
    #expect(!manager.canUndo)
    manager.redo()
    #expect(f.textView.string == "Zbc")
    #expect(!manager.canRedo)
}

// MARK: Undo group ownership

@Test @MainActor
func callersExplicitGroupIsNeverClosedAndKeepsItsStepsTogether() throws {
    let f = Fixture("abc")
    let manager = f.editor.undo.undoManager
    f.endEvent()
    manager.beginUndoGrouping()                       // the caller's own group
    let depth = manager.groupingLevel
    f.textView.insertText("X", replacementRange: NSRange(location: 3, length: 0))
    let depthWithTyping = manager.groupingLevel
    try f.session.apply(
        [DocumentEdit(range: UTF16TextRange(location: 0, length: 1), replacement: "AAA")],
        expectedVersion: 1, origin: .formatting
    )
    #expect(manager.groupingLevel == depthWithTyping)
    #expect(depth >= 1)
    manager.endUndoGrouping()                          // pairing intact: must not raise
    f.endEvent()
    #expect(manager.groupingLevel == 0)
    manager.undo()                                     // the caller asked for one group
    #expect(f.textView.string == "abc")
    #expect(!manager.canUndo)
}

@Test @MainActor
func refusedPreflightRegistersNothingAndLeavesProgrammaticStepOnTop() throws {
    let f = Fixture("abc")
    try f.session.replaceText("xyz", expectedVersion: 0)
    // Our preflight refuses before AppKit gets to register anything.
    #expect(!f.textView.shouldChangeText(in: NSRange(location: 99, length: 1), replacementString: "Q"))
    f.endEvent()
    let manager = f.editor.undo.undoManager
    manager.undo()
    #expect(f.textView.string == "abc")
    #expect(f.session.text == "abc")
    #expect(!manager.canUndo)
}

/// `shouldChangeText` promises a change. AppKit itself registers its undo action there, so a
/// caller that never changes anything leaves an action only AppKit can explain (verified on a
/// plain NSTextView). What the bridge guarantees: no leaked state and no open group.
@Test @MainActor
func unmatchedPreflightLeaksNoBridgeStateAndKeepsSessionInSync() throws {
    let f = Fixture("abc")
    try f.session.replaceText("xyz", expectedVersion: 0)
    #expect(f.textView.shouldChangeText(in: NSRange(location: 0, length: 0), replacementString: "Q"))
    f.textView.didChangeText()
    f.endEvent()
    let manager = f.editor.undo.undoManager
    #expect(manager.groupingLevel == 0)

    // The stale preflight must not be mistaken for the next real edit.
    f.type("!", at: 3)
    #expect(f.log.changes.last?.isReconciled == false)
    #expect(f.log.changes.last?.edits == [DocumentEdit(range: UTF16TextRange(location: 3, length: 0), replacement: "!")])
    while manager.canUndo { manager.undo(); f.endEvent() }
    #expect(f.session.text == f.textView.string)
    #expect(manager.groupingLevel == 0)
}

@Test @MainActor
func typingProgrammaticTypingInOnePassGivesThreeSeparateSteps() throws {
    let f = Fixture("abc")
    f.textView.insertText("a", replacementRange: NSRange(location: 3, length: 0))     // abca
    try f.session.apply(
        [DocumentEdit(range: UTF16TextRange(location: 0, length: 1), replacement: "Z")],
        expectedVersion: 1, origin: .formatting
    )                                                                                    // Zbca
    f.textView.insertText("b", replacementRange: NSRange(location: 4, length: 0))     // Zbcab
    f.endEvent()
    let manager = f.editor.undo.undoManager
    manager.undo(); #expect(f.textView.string == "Zbca")
    manager.undo(); #expect(f.textView.string == "abca")
    manager.undo(); #expect(f.textView.string == "abc")
    #expect(!manager.canUndo)
    #expect(f.session.text == "abc")
}

@Test @MainActor
func openGroupsAreAlwaysClosedByTheRunLoopAfterMixedOperations() throws {
    let f = Fixture("abc")
    let manager = f.editor.undo.undoManager
    f.textView.insertText("a", replacementRange: NSRange(location: 3, length: 0))
    try f.session.apply(
        [DocumentEdit(range: UTF16TextRange(location: 0, length: 1), replacement: "Z")],
        expectedVersion: 1, origin: .formatting
    )
    f.textView.insertText("b", replacementRange: NSRange(location: 4, length: 0))
    f.endEvent()
    #expect(manager.groupingLevel == 0)
    // A later command in a fresh event behaves the same.
    try f.session.apply(
        [DocumentEdit(range: UTF16TextRange(location: 0, length: 1), replacement: "Y")],
        expectedVersion: f.session.version, origin: .formatting
    )
    f.endEvent()
    #expect(manager.groupingLevel == 0)
}
