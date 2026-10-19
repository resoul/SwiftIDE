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
        log = ChangeLog(initialText: text)
        let log = log
        session.subscribeToChanges { log.record($0) }
        session.subscribeToComposition { log.composition.append($0) }
    }

    /// The text rebuilt only from the published changes, applied one after another to the text
    /// the document started with. Independent of every read of the backend: if a change were
    /// missing part of a real edit, this would differ from what the view shows.
    var replayed: String { log.replayed }

    func assertConsistent(sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(
            replayed == textView.string,
            "published changes do not add up to the view's text",
            sourceLocation: sourceLocation
        )
    }

    /// Lets the run loop close NSUndoManager's implicit per-event group, as a real event ends.
    func endEvent() {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.001))
        assertConsistent()
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
    private let mirror: NSMutableString

    init(initialText: String) {
        mirror = NSMutableString(string: initialText)
    }

    var replayed: String { String(mirror) }

    func record(_ change: DocumentChangeSet) {
        changes.append(change)
        // Edits are in coordinates of the text before the change, last position first.
        for edit in change.edits {
            mirror.replaceCharacters(
                in: NSRange(location: edit.range.location, length: edit.range.length),
                with: edit.replacement
            )
        }
    }
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
    #expect(f.log.changes[1].edits == [DocumentEdit(
        range: UTF16TextRange(location: 0, length: 3),
        replacement: "PASTED"
    )])
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
        expectedVersion: 1,
        origin: .formatting
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
    f.textView.setMarkedText(
        "k",
        selectedRange: NSRange(location: 1, length: 0),
        replacementRange: NSRange(location: 2, length: 0)
    )
    #expect(f.session.isComposing)
    #expect(f.session.text == "abk")
    f.textView.setMarkedText(
        "ka",
        selectedRange: NSRange(location: 2, length: 0),
        replacementRange: NSRange(location: NSNotFound, length: 0)
    )
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
    f.textView.setMarkedText(
        "k",
        selectedRange: NSRange(location: 1, length: 0),
        replacementRange: NSRange(location: 2, length: 0)
    )
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
    f.textView.setMarkedText(
        "k",
        selectedRange: NSRange(location: 1, length: 0),
        replacementRange: NSRange(location: 2, length: 0)
    )
    f.textView.setMarkedText(
        "",
        selectedRange: NSRange(location: 0, length: 0),
        replacementRange: NSRange(location: NSNotFound, length: 0)
    )
    #expect(f.textView.string == "ab")
    #expect(f.session.text == "ab")
    #expect(f.session.version == 2)
    #expect(!f.session.isComposing)
    #expect(f.log.composition.last == .ended)
}

@Test @MainActor
func programmaticEditIsRejectedInsideMarkedTextAndAllowedAfter() throws {
    let f = Fixture("ab")
    f.textView.setMarkedText(
        "k",
        selectedRange: NSRange(location: 1, length: 0),
        replacementRange: NSRange(location: 2, length: 0)
    )
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
    f.textView.setMarkedText(
        "k",
        selectedRange: NSRange(location: 1, length: 0),
        replacementRange: NSRange(location: 2, length: 0)
    )
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
        expectedVersion: 1,
        origin: .formatting
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
        expectedVersion: 0,
        origin: .formatting
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
        expectedVersion: 0,
        origin: .formatting
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
        expectedVersion: 1,
        origin: .formatting
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
    #expect(f.log.changes.last?.edits == [DocumentEdit(
        range: UTF16TextRange(location: 3, length: 0),
        replacement: "!"
    )])
    while manager.canUndo {
        manager.undo()
        f.endEvent()
    }
    #expect(f.session.text == f.textView.string)
    #expect(manager.groupingLevel == 0)
}

@Test @MainActor
func typingProgrammaticTypingInOnePassGivesThreeSeparateSteps() throws {
    let f = Fixture("abc")
    f.textView.insertText("a", replacementRange: NSRange(location: 3, length: 0))     // abca
    try f.session.apply(
        [DocumentEdit(range: UTF16TextRange(location: 0, length: 1), replacement: "Z")],
        expectedVersion: 1,
        origin: .formatting
    )                                                                                    // Zbca
    f.textView.insertText("b", replacementRange: NSRange(location: 4, length: 0))     // Zbcab
    f.endEvent()
    let manager = f.editor.undo.undoManager
    manager.undo()
    #expect(f.textView.string == "Zbca")
    manager.undo()
    #expect(f.textView.string == "abca")
    manager.undo()
    #expect(f.textView.string == "abc")
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
        expectedVersion: 1,
        origin: .formatting
    )
    f.textView.insertText("b", replacementRange: NSRange(location: 4, length: 0))
    f.endEvent()
    #expect(manager.groupingLevel == 0)
    // A later command in a fresh event behaves the same.
    try f.session.apply(
        [DocumentEdit(range: UTF16TextRange(location: 0, length: 1), replacement: "Y")],
        expectedVersion: f.session.version,
        origin: .formatting
    )
    f.endEvent()
    #expect(manager.groupingLevel == 0)
}

// MARK: Cost: nothing on the editing path copies the document (ADR-012)

@Test @MainActor
func noEditingOperationOnTheRealViewCopiesTheWholeText() throws {
    let f = Fixture(String(repeating: "let value = 1 // 😀\r\n", count: 2_000))
    let backend = f.editor.backend
    let manager = f.editor.undo.undoManager

    f.type("x", at: 4)                                     // typing
    f.type("PASTED", at: 0, replacing: 3)                  // paste over a selection
    try f.session.apply(                                   // programmatic (format) edit
        [DocumentEdit(range: UTF16TextRange(location: 10, length: 0), replacement: "y")],
        expectedVersion: f.session.version,
        origin: .formatting
    )
    f.endEvent()
    manager.undo()
    f.endEvent()                           // undo of the programmatic edit
    manager.undo()
    f.endEvent()                           // undo of typing (storage's own report)
    manager.redo()
    f.endEvent()
    f.textView.setMarkedText(
        "k",
        selectedRange: NSRange(location: 1, length: 0),
        replacementRange: NSRange(location: 20, length: 0)
    )
    f.textView.setMarkedText(
        "ka",
        selectedRange: NSRange(location: 2, length: 0),
        replacementRange: NSRange(location: NSNotFound, length: 0)
    )
    f.textView.insertText("か", replacementRange: NSRange(location: NSNotFound, length: 0))
    f.textView.setMarkedText(
        "z",
        selectedRange: NSRange(location: 1, length: 0),
        replacementRange: NSRange(location: 30, length: 0)
    )
    f.textView.unmarkText()
    f.endEvent()

    #expect(backend.textMaterializations == 0, "the whole text was copied on the editing path")
    #expect(f.session.reconciliationCount >= 0)
    // And all of that stayed consistent: the session's view of the document is the view's.
    let snapshot = f.session.snapshot()
    #expect(backend.textMaterializations == 1)
    #expect(snapshot.text == f.textView.string)
}

@Test @MainActor
func theViewsOwnUndoIsDescribedByItsEditedRangeNotByComparingTexts() throws {
    let f = Fixture(String(repeating: "abc\n", count: 500))
    f.type("X", at: 10)
    f.editor.undo.undoManager.undo()
    let undone = try #require(f.log.changes.last)
    #expect(undone.origin == .undo)
    // Described as the region storage reports, in coordinates of the text before the undo.
    #expect(undone.edits.count == 1)
    #expect(undone.edits[0].range == UTF16TextRange(location: 10, length: 1))
    #expect(undone.edits[0].replacement == "")
    #expect(f.editor.backend.textMaterializations == 0)
    #expect(f.session.snapshot().text == f.textView.string)
}

// MARK: Review regressions (composition end, extended edits)

@Test @MainActor
func compositionEndIsAnnouncedOnlyWhenTheOperationIsAccountedFor() {
    let f = Fixture("ab")
    f.textView.setMarkedText(
        "k",
        selectedRange: NSRange(location: 1, length: 0),
        replacementRange: NSRange(location: 2, length: 0)
    )
    let versionBefore = f.session.version
    var seen: [(text: String, version: UInt64, reconciliations: Int)] = []
    f.session.subscribeToComposition { event in
        guard event == .ended else { return }

        let snapshot = f.session.snapshot()
        seen.append((snapshot.text, snapshot.version, f.session.reconciliationCount))
    }

    // unmarkText removes the marked text and puts it back; nobody may look in between.
    f.textView.unmarkText()

    #expect(seen.count == 1)
    #expect(seen.first?.text == "abk", "the snapshot taken on .ended is the finished text")
    #expect(seen.first?.version == versionBefore, "unmarking without a text change is not a revision")
    #expect(seen.first?.reconciliations == 0)
    f.assertConsistent()
}

@Test @MainActor
func compositionEndedByCommittingTextSeesTheFinishedText() {
    let f = Fixture("ab")
    f.textView.setMarkedText(
        "ka",
        selectedRange: NSRange(location: 2, length: 0),
        replacementRange: NSRange(location: 2, length: 0)
    )
    var atEnd: DocumentSnapshot?
    f.session.subscribeToComposition { if $0 == .ended { atEnd = f.session.snapshot() } }
    f.textView.insertText("か", replacementRange: NSRange(location: NSNotFound, length: 0))
    #expect(atEnd?.text == "abか")
    #expect(atEnd?.version == f.session.version)
    f.assertConsistent()
}

@Test @MainActor
func aDeclaredEditThatStorageExtendedIsPublishedAsTheWholeChangedRegion() throws {
    let f = Fixture("abcdef")
    // The preflight announces a → X; in the same transaction something also changes f → Y.
    #expect(f.textView.shouldChangeText(in: NSRange(location: 0, length: 1), replacementString: "X"))
    let storage = try #require(f.textView.textStorage)
    storage.beginEditing()
    storage.replaceCharacters(in: NSRange(location: 0, length: 1), with: "X")
    storage.replaceCharacters(in: NSRange(location: 5, length: 1), with: "Y")
    storage.endEditing()
    f.textView.didChangeText()

    #expect(f.textView.string == "XbcdeY")
    #expect(f.session.version == 1)
    let change = try #require(f.log.changes.last)
    #expect(change.isReconciled, "the declared edit was not the whole story")
    f.assertConsistent()   // fails if the f → Y part is lost from the published changes
    #expect(f.editor.compatibility.isTextKit2)
}

// MARK: Tab

@Test @MainActor
func theTabKeyTypesSpacesUpToTheNextIndentColumnAndStaysConsistent() {
    let fixture = Fixture("    a\n  \nxy")
    fixture.textView.setSelectedRange(NSRange(location: 6 + 2, length: 0))
    fixture.textView.insertTab(nil)
    fixture.endEvent()
    #expect(fixture.textView.string == "    a\n    \nxy")
    fixture.textView.setSelectedRange(NSRange(location: fixture.textView.string.utf16.count, length: 0))
    fixture.textView.insertTab(nil)
    fixture.endEvent()
    #expect(fixture.textView.string.hasSuffix("xy  "))
    fixture.assertConsistent()
}

@Test @MainActor
func aTabCharacterIsAsWideAsAnIndentLevel() throws {
    let editor = TextKitEditorFactory.makeEditor(loadedText: "\tx")
    let style = try #require(editor.textView.defaultParagraphStyle)
    let space = (" " as NSString).size(withAttributes: [.font: try #require(editor.textView.font)]).width
    #expect(style.tabStops.isEmpty && abs(style.defaultTabInterval - 4 * space) < 0.001)
}

@Test @MainActor
func returnKeepsTheIndentationOfTheLineAndIsForANewLine() {
    let fixture = Fixture("func f() {\n    let a = 1\n}")
    fixture.textView.setSelectedRange(NSRange(location: 24, length: 0))
    fixture.textView.insertNewline(nil)
    fixture.endEvent()
    #expect(fixture.textView.string == "func f() {\n    let a = 1\n    \n}")
    fixture.textView.setSelectedRange(NSRange(location: 13, length: 0))
    fixture.textView.insertNewline(nil)
    fixture.endEvent()
    #expect(fixture.textView.string.hasPrefix("func f() {\n  \n  "))
    fixture.assertConsistent()
}

@Test @MainActor
func returnAfterAnOpeningBracketGoesDeeperAndSplitsAnEmptyPair() {
    let fixture = Fixture("func f() {}\n")
    fixture.textView.setSelectedRange(NSRange(location: 10, length: 0))
    fixture.textView.insertNewline(nil)
    fixture.endEvent()
    #expect(fixture.textView.string == "func f() {\n    \n}\n")
    #expect(fixture.textView.selectedRange() == NSRange(location: 15, length: 0))
    fixture.textView.insertText("let a = 1(", replacementRange: NSRange(location: 15, length: 0))
    fixture.textView.insertNewline(nil)
    fixture.endEvent()
    #expect(fixture.textView.string == "func f() {\n    let a = 1(\n        \n}\n")
    fixture.assertConsistent()
}

@Test @MainActor
func aClosingBracketOnAnIndentationOnlyLineStepsBackOneLevel() {
    let fixture = Fixture("{\n        \n")
    fixture.textView.setSelectedRange(NSRange(location: 10, length: 0))
    fixture.textView.insertText("}", replacementRange: NSRange(location: NSNotFound, length: 0))
    fixture.endEvent()
    #expect(fixture.textView.string == "{\n    }\n")
    fixture.textView.setSelectedRange(NSRange(location: 6, length: 0))
    fixture.textView.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
    fixture.textView.insertText("}", replacementRange: NSRange(location: NSNotFound, length: 0))
    fixture.endEvent()
    #expect(fixture.textView.string == "{\n    x}\n", "the typed bracket steps over the one in front of it")
    fixture.assertConsistent()
}

// MARK: Pairs and code-aware indent

@MainActor
private func typed(_ fixture: Fixture, _ text: String) {
    for character in text {
        fixture.textView.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
    }
    fixture.endEvent()
}

@Test @MainActor
func anOpeningBracketAddsItsPartnerAndTheClosingOneStepsOver() {
    let fixture = Fixture("")
    typed(fixture, "f(a[0], \"s\")")
    #expect(fixture.textView.string == "f(a[0], \"s\")")
    #expect(fixture.textView.selectedRange().location == 12)
    typed(fixture, "{")
    #expect(fixture.textView.string == "f(a[0], \"s\"){}")
    fixture.textView.deleteBackward(nil)
    fixture.endEvent()
    #expect(fixture.textView.string == "f(a[0], \"s\")")
    fixture.assertConsistent()
}

@Test @MainActor
func pairsAreNotAddedInStringsCommentsOrBeforeWords() {
    let fixture = Fixture("")
    typed(fixture, "// (")
    #expect(fixture.textView.string == "// (")
    fixture.textView.insertText("\n", replacementRange: NSRange(location: NSNotFound, length: 0))
    typed(fixture, "\"a(")
    #expect(fixture.textView.string.hasSuffix("\n\"a(\""))
    let word = Fixture("")
    typed(word, "x(it\"s")
    #expect(word.textView.string == "x(it\"s)")
}

@Test @MainActor
func aBracketInAStringOrACommentDoesNotIndentTheNextLine() {
    let fixture = Fixture("let a = \"{\"\n")
    fixture.textView.setSelectedRange(NSRange(location: 12, length: 0))
    fixture.textView.insertNewline(nil)
    #expect(fixture.textView.string == "let a = \"{\"\n\n")
    let comment = Fixture("x = 1 // {")
    comment.textView.setSelectedRange(NSRange(location: 10, length: 0))
    comment.textView.insertNewline(nil)
    #expect(comment.textView.string == "x = 1 // {\n")
}

// MARK: Duplicate line

@MainActor
private func duplicate(_ text: String, selecting range: NSRange) -> (text: String, selection: NSRange) {
    let fixture = Fixture(text)
    fixture.textView.setSelectedRange(range)
    (fixture.textView as? CodeLineActions)?.duplicateLine(nil)
    fixture.endEvent()

    return (fixture.textView.string, fixture.textView.selectedRange())
}

@Test @MainActor
func duplicateLineCopiesTheCaretLineBelowAndKeepsTheColumn() {
    let result = duplicate("a\n  bc\nd\n", selecting: NSRange(location: 5, length: 0))
    #expect(result.text == "a\n  bc\n  bc\nd\n")
    #expect(result.selection == NSRange(location: 5 + 5, length: 0))
}

@Test @MainActor
func duplicateLineOnTheLastLineWithoutANewlineAddsOne() {
    let result = duplicate("a\nbc", selecting: NSRange(location: 4, length: 0))
    #expect(result.text == "a\nbc\nbc")
    #expect(result.selection == NSRange(location: 7, length: 0))
}

@Test @MainActor
func duplicateLineRepeatsAFragmentOrWholeLinesAndSelectsTheCopy() {
    let fragment = duplicate("let ab = 1\n", selecting: NSRange(location: 4, length: 2))
    #expect(fragment.text == "let abab = 1\n" && fragment.selection == NSRange(location: 6, length: 2))
    let block = duplicate("a\nb\nc\n", selecting: NSRange(location: 1, length: 3))
    #expect(block.text == "a\nb\na\nb\nc\n")
    #expect(block.selection == NSRange(location: 5, length: 3))
}

@Test @MainActor
func duplicateLineIsOneUndoStep() {
    let fixture = Fixture("a\n")
    (fixture.textView as? CodeLineActions)?.duplicateLine(nil)
    fixture.endEvent()
    fixture.editor.undo.undoManager.undo()
    fixture.endEvent()
    #expect(fixture.textView.string == "a\n")
}

// MARK: Toggle line comment

@MainActor
private func toggleComment(
    _ text: String,
    selecting range: NSRange,
    marker: String? = "//"
) -> (text: String, selection: NSRange) {
    let fixture = Fixture(text)
    fixture.editor.input.lineCommentPrefix = { marker }
    fixture.textView.setSelectedRange(range)
    (fixture.textView as? CodeLineActions)?.toggleLineComment(nil)
    fixture.endEvent()

    return (fixture.textView.string, fixture.textView.selectedRange())
}

@Test @MainActor
func toggleCommentMarksAndUnmarksTheCaretLineAndKeepsTheCaretOnTheText() {
    let on = toggleComment("a\n    b = 1\n", selecting: NSRange(location: 8, length: 0))
    #expect(on.text == "a\n    // b = 1\n" && on.selection == NSRange(location: 11, length: 0))
    let off = toggleComment(on.text, selecting: on.selection)
    #expect(off.text == "a\n    b = 1\n" && off.selection == NSRange(location: 8, length: 0))
}

@Test @MainActor
func toggleCommentOnABlockUsesTheShallowestIndentAndSkipsBlankLines() {
    let text = "    a\n\n      b\n"
    let on = toggleComment(text, selecting: NSRange(location: 0, length: 14))
    #expect(on.text == "    // a\n\n    //   b\n")
    let off = toggleComment(on.text, selecting: NSRange(location: 0, length: on.text.utf16.count - 1))
    #expect(off.text == text)
}

@Test @MainActor
func toggleCommentLeavesAMixedBlockToBeCommentedAndIgnoresAnEndAtLineStart() {
    let mixed = toggleComment("// a\nb\n", selecting: NSRange(location: 0, length: 7))
    #expect(mixed.text == "// // a\n// b\n")
    let partial = toggleComment("a\nb\n", selecting: NSRange(location: 0, length: 2))
    #expect(partial.text == "// a\nb\n")
}

@Test @MainActor
func toggleCommentDoesNothingWithoutAMarkerAndIsOneUndoStep() {
    #expect(toggleComment("a\n", selecting: NSRange(location: 0, length: 0), marker: nil).text == "a\n")
    let fixture = Fixture("a\nb\n")
    fixture.editor.input.lineCommentPrefix = { "//" }
    fixture.textView.setSelectedRange(NSRange(location: 0, length: 3))
    (fixture.textView as? CodeLineActions)?.toggleLineComment(nil)
    fixture.endEvent()
    fixture.editor.undo.undoManager.undo()
    fixture.endEvent()
    #expect(fixture.textView.string == "a\nb\n")
}
