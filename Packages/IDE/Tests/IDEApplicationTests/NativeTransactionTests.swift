import Foundation
import IDEApplication
import IDEDomain
import IDETestSupport
import Testing

@MainActor
private func makeSession(_ text: String) -> (DocumentSession, StringDocumentBackend, Recorder) {
    let backend = StringDocumentBackend(loadedText: text)
    let session = DocumentSession(path: "Main.swift", backend: backend)
    let recorder = Recorder()
    session.subscribeToChanges { recorder.changes.append($0) }

    return (session, backend, recorder)
}

@MainActor
private final class Recorder {
    var changes: [DocumentChangeSet] = []
}

private actor RecordingStore: DocumentFileStore {
    private(set) var snapshots: [DocumentSnapshot] = []
    func read(path: String, maximumBytes: Int) async throws -> LoadedFile { throw FileStoreError.notFound }
    func write(_ snapshot: DocumentSnapshot, expecting: SaveExpectation) async throws -> FileRevision {
        snapshots.append(snapshot)

        return .stub(Int64(snapshots.count))
    }
}

private func edit(_ location: Int, _ length: Int, _ replacement: String) -> DocumentEdit {
    DocumentEdit(range: UTF16TextRange(location: location, length: length), replacement: replacement)
}

// MARK: Accounting for native edits

@Test @MainActor
func exactNativeEditPublishesOneRevisionWithoutTouchingBackend() {
    let (session, backend, recorder) = makeSession("abc")
    backend.simulateNativeEdit(UTF16TextRange(location: 1, length: 1), with: "XY")
    #expect(session.version == 1)
    #expect(recorder.changes.count == 1)
    #expect(recorder.changes[0].edits == [edit(1, 1, "XY")])
    #expect(recorder.changes[0].origin == .typing)
    #expect(!recorder.changes[0].isReconciled)
    #expect(session.reconciliationCount == 0)
    #expect(session.text == "aXYc")
}

@Test @MainActor
func repeatedDeliveryOfTheSameCommitDoesNotBumpTheVersionTwice() {
    let (session, backend, recorder) = makeSession("abc")
    let commit = backend.simulateNativeEdit(UTF16TextRange(location: 0, length: 0), with: "x")
    backend.reportAgain(commit)
    backend.reportAgain(commit)
    #expect(session.version == 1)
    #expect(recorder.changes.count == 1)
    #expect(session.reconciliationCount == 0)
}

@Test @MainActor
func anUnchangedEffectCreatesNoRevisionButIsStillAccountedFor() throws {
    let (session, backend, recorder) = makeSession("abc")
    // Characters replaced by themselves: what an attribute pass looks like to the session.
    backend.simulateNativeEdit(
        UTF16TextRange(location: 0, length: 3),
        with: "abc",
        report: .claiming(.unchanged)
    )
    #expect(session.version == 0)
    #expect(recorder.changes.isEmpty)
    #expect(!session.isDirty)
    // The pass was accounted for, so it is not mistaken for an edit behind the session's back.
    try session.replaceText("next", expectedVersion: 0)
    #expect(session.version == 1)
    #expect(recorder.changes.count == 1 && !recorder.changes[0].isReconciled)
}

@Test @MainActor
func aRegionOnlyEffectIsPublishedAsReconciledWithoutRejecting() {
    let (session, backend, recorder) = makeSession("hello world")
    backend.simulateNativeEdit(UTF16TextRange(location: 6, length: 5), with: "swift", report: .derived)
    #expect(session.text == "hello swift")
    #expect(session.version == 1)
    #expect(recorder.changes[0].edits == [edit(6, 5, "swift")])
    #expect(recorder.changes[0].isReconciled)
    #expect(session.reconciliationCount == 1)
}

@Test @MainActor
func aCommitThatContradictsTheBackendBecomesAWholeDocumentReplacement() {
    let (session, backend, recorder) = makeSession("hello world")
    // The view claims it inserted "zzz" at the start; the backend's length says otherwise.
    backend.simulateNativeEdit(
        UTF16TextRange(location: 6, length: 5),
        with: "swift",
        report: .claiming(.replaced(range: UTF16TextRange(location: 0, length: 0), replacement: "zzz", isExact: true))
    )
    #expect(session.version == 1)
    #expect(recorder.changes[0].edits == [edit(0, 11, "hello swift")])
    #expect(recorder.changes[0].isReconciled)
    #expect(session.text == "hello swift")
}

@Test @MainActor
func anEffectTheEditorCannotDescribeBecomesAWholeDocumentReplacement() {
    let (session, backend, recorder) = makeSession("abc")
    backend.simulateNativeEdit(UTF16TextRange(location: 1, length: 1), with: "Z", report: .unknown)
    #expect(recorder.changes[0].edits == [edit(0, 3, "aZc")])
    #expect(recorder.changes[0].isReconciled)
    #expect(session.version == 1)
}

@Test @MainActor
func snapshotsStayPairedWithTheVersionEvenAfterAnUnreportedEdit() {
    let (session, backend, _) = makeSession("a")
    let old = session.snapshot()
    backend.simulateNativeEdit(UTF16TextRange(location: 1, length: 0), with: "b", report: .silent)
    let new = session.snapshot()
    #expect(old.version == 0 && old.text == "a")
    #expect(new.version == 1 && new.text == "ab")
}

@Test @MainActor
func anUnreportedEditIsPickedUpBeforeTheNextProgrammaticPlan() throws {
    let (session, backend, recorder) = makeSession("abc")
    backend.simulateNativeEdit(UTF16TextRange(location: 0, length: 1), with: "X", report: .silent)
    // A programmatic edit planned against the old document is refused, not applied to wrong text.
    #expect(throws: DocumentError.staleVersion(expected: 0, actual: 1)) {
        try session.replaceText("new", expectedVersion: 0)
    }
    #expect(session.text == "Xbc")
    #expect(recorder.changes.count == 1)
    #expect(recorder.changes[0].isReconciled)
}

@Test @MainActor
func aSkippedPassMakesTheNextCommitUntrustworthy() {
    let (session, backend, recorder) = makeSession("abc")
    backend.simulateNativeEdit(UTF16TextRange(location: 0, length: 0), with: "1", report: .silent)
    // The next, reported edit is relative to text the session never saw.
    backend.simulateNativeEdit(UTF16TextRange(location: 4, length: 0), with: "2")
    #expect(session.text == "abc12" || session.text == "1abc2")
    #expect(session.version == 1)
    #expect(recorder.changes.count == 1)
    #expect(recorder.changes[0].isReconciled)
    #expect(recorder.changes[0].edits.map { $0.range } == [UTF16TextRange(location: 0, length: 3)])
}

@Test @MainActor
func nativeMutationDuringPublicationIsDeferredNotReordered() throws {
    let (session, backend, recorder) = makeSession("abc")
    var injected = false
    session.subscribeToChanges { _ in
        guard !injected else { return }

        injected = true
        backend.simulateNativeEdit(UTF16TextRange(location: 3, length: 0), with: "!")
        #expect(!backend.allowsNativeEdit)
    }
    try session.replaceText("xyz", expectedVersion: 0)
    #expect(session.version == 2)
    #expect(session.text == "xyz!")
    #expect(recorder.changes.map(\.newVersion) == [1, 2])
    #expect(recorder.changes[1].edits == [edit(3, 0, "!")])
}

@Test @MainActor
func nativeEditsAreRefusedWhilePublishing() throws {
    let (session, backend, _) = makeSession("abc")
    var allowedDuring: Bool?
    session.subscribeToChanges { _ in allowedDuring = backend.allowsNativeEdit }
    try session.replaceText("x", expectedVersion: 0)
    #expect(allowedDuring == false)
    #expect(backend.allowsNativeEdit)
}

@Test @MainActor
func editingNeverCopiesTheWholeText() throws {
    let (session, backend, _) = makeSession(String(repeating: "line of text\n", count: 1_000))
    backend.simulateNativeEdit(UTF16TextRange(location: 5, length: 0), with: "x")
    backend.simulateNativeEdit(UTF16TextRange(location: 6, length: 1), with: "yz", report: .derived)
    try session.replaceText("replaced", expectedVersion: session.version)
    try session.apply([edit(0, 0, "a"), edit(3, 1, "")], expectedVersion: session.version)
    #expect(backend.textMaterializations == 0, "typing and programmatic edits are O(edit)")
    _ = session.snapshot()
    #expect(backend.textMaterializations == 1, "only a snapshot copies the document")
}

// MARK: Composition and save gate

@Test @MainActor
func programmaticEditsAreRejectedWhileComposing() throws {
    let (session, backend, _) = makeSession("abc")
    backend.simulateComposition(.began)
    #expect(session.isComposing)
    #expect(throws: DocumentError.compositionInProgress) {
        try session.replaceText("x", expectedVersion: 0)
    }
    backend.simulateComposition(.ended)
    try session.replaceText("x", expectedVersion: 0)
    #expect(session.text == "x")
}

@Test @MainActor
func compositionEndWithoutTextChangeNotifiesWithoutVersionBump() {
    let (session, backend, recorder) = makeSession("abc")
    var events: [CompositionEvent] = []
    session.subscribeToComposition { events.append($0) }
    backend.simulateComposition(.began)
    backend.simulateComposition(.updated)
    backend.simulateComposition(.ended)
    #expect(events == [.began, .updated, .ended])
    #expect(session.version == 0)
    #expect(recorder.changes.isEmpty)
    #expect(!session.isComposing)
}

@Test @MainActor
func explicitSaveRequestsEndAndWaitsThenWritesFinalSnapshot() async throws {
    let (session, backend, _) = makeSession("abc")
    let store = RecordingStore()
    let save = SaveDocumentUseCase(store: store)
    backend.simulateComposition(.began)
    backend.simulateNativeEdit(UTF16TextRange(location: 3, length: 0), with: "é", origin: .composition)

    let task = Task { try await save.execute(document: session, trigger: .explicit) }
    await Task.yield()
    #expect(backend.endCompositionRequests == 1)
    #expect(await store.snapshots.isEmpty)

    // Last composition step arrives before the input method finishes, then it ends.
    backend.simulateNativeEdit(UTF16TextRange(location: 3, length: 1), with: "ée", origin: .composition)
    backend.simulateComposition(.ended)
    let receipt = try await task.value
    #expect(receipt.savedVersion == 2)
    #expect(receipt.isCurrent)
    #expect(await store.snapshots.map(\.text) == ["abcée"])
}

@Test @MainActor
func autosaveWaitsWithoutInterruptingInput() async throws {
    let (session, backend, _) = makeSession("abc")
    let store = RecordingStore()
    let save = SaveDocumentUseCase(store: store)
    backend.simulateComposition(.began)
    let task = Task { try await save.execute(document: session, trigger: .autosave) }
    await Task.yield()
    await Task.yield()
    #expect(backend.endCompositionRequests == 0)
    #expect(await store.snapshots.isEmpty)
    backend.simulateComposition(.ended)
    _ = try await task.value
    #expect(await store.snapshots.count == 1)
}

@Test @MainActor
func cancelledSaveStopsWaitingForComposition() async {
    let (session, backend, _) = makeSession("abc")
    let save = SaveDocumentUseCase(store: RecordingStore())
    backend.simulateComposition(.began)
    let task = Task { try await save.execute(document: session, trigger: .autosave) }
    await Task.yield()
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    // A later save is not blocked by the cancelled one.
    backend.simulateComposition(.ended)
    _ = try? await save.execute(document: session)
}

// MARK: Pure helpers

/// Applies a batch of edits (original coordinates) to a plain string, the slow obvious way.
private func applying(_ edits: [DocumentEdit], to text: String) -> String {
    let result = NSMutableString(string: text)
    for edit in edits.sorted(by: { $0.range.location > $1.range.location }) {
        result.replaceCharacters(
            in: NSRange(location: edit.range.location, length: edit.range.length),
            with: edit.replacement
        )
    }

    return String(result)
}

@Test @MainActor
func inverseEditsRestoreSourceInPostChangeCoordinates() throws {
    let source = "a😀bcd"
    let plan = try #require(try DocumentEditPlanner.prepare([edit(0, 1, "AAA"), edit(4, 1, "")], in: StringTextSource(source)))
    let after = applying(plan.edits, to: source)
    #expect(after == "AAA😀bd")
    #expect(applying(plan.inverseEdits, to: after) == source)
    #expect(plan.sourceLength == 6 && plan.resultLength == after.utf16.count)
}

@Test @MainActor
func plannerReadsOnlyWhatTheEditsReplace() throws {
    final class CountingSource: TextSource {
        let inner = StringTextSource(String(repeating: "x", count: 10_000))
        var unitsRead = 0
        var charactersCopied = 0
        var utf16Length: Int { inner.utf16Length }
        func utf16Unit(at index: Int) -> UInt16 { unitsRead += 1; return inner.utf16Unit(at: index) }
        func substring(in range: UTF16TextRange) -> String {
            charactersCopied += range.length

            return inner.substring(in: range)
        }
    }
    let source = CountingSource()
    _ = try DocumentEditPlanner.prepare([edit(5_000, 2, "yy!")], in: source)
    #expect(source.unitsRead <= 4)
    #expect(source.charactersCopied == 2)
}

@Test
func regionAccumulatorFoldsPassesIntoOneReplacement() {
    // Remove the marked "k" and put it back, as unmarkText does.
    var region = EditRegionAccumulator()
    region.record(editedRange: UTF16TextRange(location: 2, length: 0), changeInLength: -1)
    region.record(editedRange: UTF16TextRange(location: 2, length: 1), changeInLength: 1)
    #expect(region.rangeBefore == UTF16TextRange(location: 2, length: 1))
    #expect(region.rangeAfter == UTF16TextRange(location: 2, length: 1))
}

@Test
func regionAccumulatorCoversEveryChangeOfRandomPassSequences() {
    var generator = SeededGenerator(seed: 0xBADC0DE)
    let pieces = ["a", "b", "😀", "é", "\r\n", "xyz"]
    for iteration in 0..<500 {
        let before = (0..<Int.random(in: 0...20, using: &generator))
            .map { _ in pieces.randomElement(using: &generator)! }.joined()
        var current = NSMutableString(string: before)
        var region = EditRegionAccumulator()
        for _ in 0..<Int.random(in: 1...5, using: &generator) {
            let length = current.length
            let location = Int.random(in: 0...length, using: &generator)
            let removed = Int.random(in: 0...(length - location), using: &generator)
            let inserted = ["", "Q", "QQ", "long insert"].randomElement(using: &generator)!
            current.replaceCharacters(in: NSRange(location: location, length: removed), with: inserted)
            region.record(
                editedRange: UTF16TextRange(location: location, length: inserted.utf16.count),
                changeInLength: inserted.utf16.count - removed
            )
        }
        let after = String(current)
        let rangeBefore = region.rangeBefore
        let rangeAfter = region.rangeAfter
        let note = "seed 0xBADC0DE iteration \(iteration)"
        #expect(rangeBefore.length >= 0, Comment(rawValue: note))
        let rebuilt = (before as NSString).replacingCharacters(
            in: NSRange(location: rangeBefore.location, length: rangeBefore.length),
            with: (after as NSString).substring(with: NSRange(location: rangeAfter.location, length: rangeAfter.length))
        )
        #expect(rebuilt == after, Comment(rawValue: note))
    }
}

// MARK: Regressions

@Test @MainActor
func inverseOfTouchingEditsIsNormalizedAndAlwaysApplicable() throws {
    let source = "abcd"
    let plan = try #require(try DocumentEditPlanner.prepare([edit(1, 1, ""), edit(2, 1, "")], in: StringTextSource(source)))
    let after = applying(plan.edits, to: source)
    #expect(after == "ad")
    let inverse = plan.inverseEdits
    #expect(inverse == [edit(1, 0, "bc")])
    let back = try #require(try DocumentEditPlanner.prepare(inverse, in: StringTextSource(after)))
    #expect(applying(back.edits, to: after) == source)
}

@Test @MainActor
func inverseRoundTripsForRandomValidBatches() throws {
    var generator = SeededGenerator(seed: 0xC0FFEE)
    let pieces = ["a", "b", "😀", "é", "\r\n", "e\u{301}"]
    for iteration in 0..<400 {
        let source = (0..<Int.random(in: 0...12, using: &generator))
            .map { _ in pieces.randomElement(using: &generator)! }.joined()
        let total = source.utf16.count
        var edits: [DocumentEdit] = []
        var cursor = 0
        for _ in 0..<8 where cursor <= total {
            let start = Int.random(in: cursor...total, using: &generator)
            let maxLen = total - start
            let len = Int.random(in: 0...min(3, maxLen), using: &generator)
            let candidate = edit(start, len, ["", "Z", "ZZ", "😀"].randomElement(using: &generator)!)
            if (try? DocumentEditPlanner.prepare(edits + [candidate], in: StringTextSource(source))) != nil {
                edits.append(candidate)
            }

            cursor = start + len + (Bool.random(using: &generator) ? 0 : 1)
        }
        guard let plan = try DocumentEditPlanner.prepare(edits, in: StringTextSource(source)) else { continue }

        let after = applying(plan.edits, to: source)
        let back = try #require(
            try DocumentEditPlanner.prepare(plan.inverseEdits, in: StringTextSource(after)),
            "seed 0xC0FFEE iteration \(iteration): inverse of \(edits) on \(source.debugDescription)"
        )
        #expect(applying(back.edits, to: after) == source, "seed 0xC0FFEE iteration \(iteration)")
    }
}

private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407

        return state
    }
}

@Test @MainActor
func explicitSaveJoinsAndPromotesPendingAutosave() async throws {
    let (session, backend, _) = makeSession("abc")
    let store = RecordingStore()
    let save = SaveDocumentUseCase(store: store)
    backend.simulateComposition(.began)

    let autosave = Task { try await save.execute(document: session, trigger: .autosave) }
    await Task.yield()
    #expect(backend.endCompositionRequests == 0)

    let explicit = Task { try await save.execute(document: session, trigger: .explicit) }
    await Task.yield()
    await Task.yield()
    // The waiting autosave was promoted: composition is asked to finish, no saveInProgress.
    #expect(backend.endCompositionRequests == 1)

    backend.simulateNativeEdit(UTF16TextRange(location: 3, length: 0), with: "!", origin: .composition)
    backend.simulateComposition(.ended)
    let first = try await autosave.value
    let second = try await explicit.value
    #expect(first == second)
    #expect(second.savedVersion == 1)
    #expect(await store.snapshots.map(\.text) == ["abc!"])
}

@Test @MainActor
func explicitSaveRetriesWhenTheWaitingAutosaveIsCancelled() async throws {
    let (session, backend, _) = makeSession("abc")
    let store = RecordingStore()
    let save = SaveDocumentUseCase(store: store)
    backend.simulateComposition(.began)
    let autosave = Task { try await save.execute(document: session, trigger: .autosave) }
    await Task.yield()
    let explicit = Task { try await save.execute(document: session, trigger: .explicit) }
    await Task.yield()
    autosave.cancel()
    await Task.yield()
    await Task.yield()
    backend.simulateComposition(.ended)
    let receipt = try await explicit.value
    #expect(receipt.isCurrent)
    #expect(await store.snapshots.count == 1)
    await #expect(throws: CancellationError.self) { try await autosave.value }
}

// MARK: Edits that cancel each other

@Test @MainActor
func editsThatCancelEachOtherAreNotARevision() throws {
    // "ab": remove "a" and insert "a" right after it. Each edit alone is a change, the batch is not.
    let (session, backend, recorder) = makeSession("ab")
    try session.apply([edit(0, 1, ""), edit(1, 0, "a")], expectedVersion: 0)
    #expect(session.version == 0)
    #expect(!session.isDirty)
    #expect(recorder.changes.isEmpty)
    #expect(backend.text == "ab")
}

@Test @MainActor
func aCancellingPairBesideARealEditKeepsOnlyTheRealEdit() throws {
    // "b" is removed and put back (a no-op as a pair); "d" really becomes "D".
    let plan = try #require(try DocumentEditPlanner.prepare(
        [edit(1, 1, ""), edit(2, 0, "b"), edit(3, 1, "D")],
        in: StringTextSource("abcd")
    ))
    #expect(plan.edits == [edit(3, 1, "D")])
    #expect(plan.replaced == ["d"])
    #expect(applying(plan.edits, to: "abcd") == "abcD")
}

@Test @MainActor
func aClusterThatChangesTextKeepsAllItsEdits() throws {
    // Remove "b" and insert "X" next to it: touching, but not cancelling.
    let plan = try #require(try DocumentEditPlanner.prepare([edit(1, 1, ""), edit(2, 0, "X")], in: StringTextSource("abcd")))
    #expect(plan.edits.count == 2)
    #expect(applying(plan.edits, to: "abcd") == "aXcd")
}

@Test @MainActor
func independentEditsAreUntouchedByTheCancellationCheck() throws {
    let plan = try #require(try DocumentEditPlanner.prepare([edit(0, 1, "A"), edit(3, 1, "D")], in: StringTextSource("abcd")))
    #expect(plan.edits.count == 2)
}

@Test @MainActor
func editsApartButWithinReachCancelAndEditsBeyondItAreTakenAsReal() throws {
    // "aaaa": the first two units become "a" and an "a" is inserted before the last: same text.
    #expect(try DocumentEditPlanner.prepare([edit(0, 2, "a"), edit(3, 0, "a")], in: StringTextSource("aaaa")) == nil)
    // The same pair, but so far apart that judging them would mean reading everything between.
    let far = String(repeating: "a", count: 4) + String(repeating: "x", count: DocumentEditPlanner.cancellationReach + 10) + "aaaa"
    let secondStart = 4 + DocumentEditPlanner.cancellationReach + 10
    let plan = try DocumentEditPlanner.prepare([edit(0, 2, "a"), edit(secondStart + 3, 0, "a")], in: StringTextSource(far))
    #expect(plan?.edits.count == 2, "beyond the reach the edits are published, never silently dropped")
}

@Test @MainActor
func aBatchIsNothingExactlyWhenApplyingItLeavesTheTextAsItWas() throws {
    var generator = SeededGenerator(seed: 0xFEEDFACE)
    let pieces = ["a", "b", "ab", "😀", "é"]
    var nothing = 0, something = 0
    for iteration in 0..<1_500 {
        let source = (0..<Int.random(in: 0...8, using: &generator))
            .map { _ in pieces.randomElement(using: &generator)! }.joined()
        let total = source.utf16.count
        // Edits that tend to touch each other and to restate the text they replace.
        var edits: [DocumentEdit] = []
        var cursor = 0
        while cursor <= total, edits.count < 5 {
            let length = Int.random(in: 0...min(2, total - cursor), using: &generator)
            let range = UTF16TextRange(location: cursor, length: length)
            let original = (source as NSString).substring(with: NSRange(location: cursor, length: length))
            let replacement = [original, "", "a", "b", String(original.reversed())].randomElement(using: &generator)!
            edits.append(DocumentEdit(range: range, replacement: replacement))
            cursor += length + Int.random(in: 0...1, using: &generator)
            if length == 0 { cursor += 1 }
        }
        let planned: PreparedDocumentEdit?
        do {
            planned = try DocumentEditPlanner.prepare(edits, in: StringTextSource(source))
        } catch {
            continue   // an invalid batch, e.g. one that splits a surrogate pair
        }
        let result = applying(edits, to: source)
        let same = result.utf8.elementsEqual(source.utf8)
        #expect((planned == nil) == same, "seed 0xFEEDFACE iteration \(iteration): \(edits) on \(source.debugDescription)")
        if let planned {
            something += 1
            #expect(applying(planned.edits, to: source) == result, "seed 0xFEEDFACE iteration \(iteration)")
        } else {
            nothing += 1
        }
    }
    #expect(nothing > 100 && something > 100, "the generator must exercise both outcomes (\(nothing)/\(something))")
}
