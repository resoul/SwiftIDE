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

// MARK: Reconciliation

@Test @MainActor
func exactNativeEditPublishesOneRevisionWithoutTouchingBackend() {
    let (session, backend, recorder) = makeSession("abc")
    backend.simulateNativeEdit(
        UTF16TextRange(location: 1, length: 1), with: "XY", exact: [edit(1, 1, "XY")]
    )
    #expect(session.text == "aXYc")
    #expect(session.version == 1)
    #expect(recorder.changes.count == 1)
    #expect(recorder.changes[0].edits == [edit(1, 1, "XY")])
    #expect(recorder.changes[0].origin == .typing)
    #expect(!recorder.changes[0].isReconciled)
    #expect(session.reconciliationCount == 0)
    #expect(backend.text == "aXYc")
}

@Test @MainActor
func repeatedCallbackOfSameTransactionDoesNotBumpVersionTwice() {
    let (session, backend, recorder) = makeSession("abc")
    let commit = backend.simulateNativeEdit(
        UTF16TextRange(location: 0, length: 0), with: "x", exact: [edit(0, 0, "x")]
    )
    backend.reportAgain(commit)
    backend.reportAgain(commit)
    #expect(session.version == 1)
    #expect(recorder.changes.count == 1)
}

@Test @MainActor
func noOpAndUnreportedAttributeOnlyCallbacksCreateNoRevision() {
    let (session, backend, recorder) = makeSession("abc")
    // Same characters replaced by themselves: what an attribute pass looks like to the session.
    backend.simulateNativeEdit(UTF16TextRange(location: 0, length: 3), with: "abc", exact: nil)
    #expect(session.version == 0)
    #expect(recorder.changes.isEmpty)
    #expect(!session.isDirty)
}

@Test @MainActor
func unexpectedNativeMutationIsReconciledByDiffNotRejected() {
    let (session, backend, recorder) = makeSession("hello world")
    // The view claimed a different edit than what really happened.
    backend.simulateNativeEdit(
        UTF16TextRange(location: 6, length: 5), with: "swift", exact: [edit(0, 0, "zzz")]
    )
    #expect(session.text == "hello swift")
    #expect(session.version == 1)
    #expect(recorder.changes.count == 1)
    #expect(recorder.changes[0].edits == [edit(6, 5, "swift")])
    #expect(recorder.changes[0].isReconciled)
    #expect(session.reconciliationCount == 1)
    #expect(backend.text == "hello swift")
}

@Test @MainActor
func mutationWithoutPreflightKeepsSnapshotConsistent() {
    let (session, backend, _) = makeSession("a")
    let old = session.snapshot()
    backend.simulateNativeEdit(UTF16TextRange(location: 1, length: 0), with: "b", exact: nil)
    let new = session.snapshot()
    #expect(old.version == 0 && old.text == "a")
    #expect(new.version == 1 && new.text == "ab")
}

@Test @MainActor
func unreportedMutationIsPickedUpBeforeNextProgrammaticPlan() throws {
    let (session, backend, recorder) = makeSession("abc")
    backend.simulateNativeEdit(UTF16TextRange(location: 0, length: 1), with: "X", report: false)
    // Programmatic edit from a stale view of the document is refused, not applied to wrong text.
    #expect(throws: DocumentError.staleVersion(expected: 0, actual: 1)) {
        try session.replaceText("new", expectedVersion: 0)
    }
    #expect(session.text == "Xbc")
    #expect(recorder.changes.count == 1)
    #expect(recorder.changes[0].isReconciled)
}

@Test @MainActor
func nativeMutationDuringPublicationIsDeferredNotReordered() throws {
    let (session, backend, recorder) = makeSession("abc")
    var injected = false
    session.subscribeToChanges { _ in
        guard !injected else { return }
        injected = true
        backend.simulateNativeEdit(UTF16TextRange(location: 3, length: 0), with: "!", exact: nil)
        #expect(!backend.allowsNativeEdit)
    }
    try session.replaceText("xyz", expectedVersion: 0)
    #expect(session.version == 2)
    #expect(session.text == "xyz!")
    #expect(recorder.changes.map(\.newVersion) == [1, 2])
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

@Test
func singleReplacementDiffIsMinimalAndKeepsSurrogatePairsWhole() {
    #expect(TextDiff.singleReplacement(from: "abc", to: "abc") == nil)
    #expect(TextDiff.singleReplacement(from: "abcd", to: "aXd") == edit(1, 2, "X"))
    #expect(TextDiff.singleReplacement(from: "", to: "hi") == edit(0, 0, "hi"))
    #expect(TextDiff.singleReplacement(from: "a", to: "") == edit(0, 1, ""))
    // 😀 = D83D DE00, 😁 = D83D DE01: only the trail unit differs, yet the pair is replaced whole.
    #expect(TextDiff.singleReplacement(from: "x😀y", to: "x😁y") == edit(1, 2, "😁"))
    #expect(TextDiff.singleReplacement(from: "a😀", to: "a😀😀") == edit(3, 0, "😀"))
}

@Test
func inverseEditsRestoreSourceInPostChangeCoordinates() throws {
    let source = "a😀bcd"
    let forward = [edit(0, 1, "AAA"), edit(4, 1, "")]
    let plan = try #require(try DocumentEditPlanner.prepare(forward, in: source))
    let back = try #require(try DocumentEditPlanner.prepare(plan.inverseEdits, in: plan.resultText))
    #expect(back.resultText == source)
    #expect(DocumentEdit.inverse(of: plan.inverseEdits, in: plan.resultText).count == 2)
}

// MARK: Regressions

@Test
func inverseOfTouchingEditsIsNormalizedAndAlwaysApplicable() throws {
    let source = "abcd"
    let plan = try #require(try DocumentEditPlanner.prepare([edit(1, 1, ""), edit(2, 1, "")], in: source))
    #expect(plan.resultText == "ad")
    let inverse = plan.inverseEdits
    #expect(inverse == [edit(1, 0, "bc")])
    let back = try #require(try DocumentEditPlanner.prepare(inverse, in: plan.resultText))
    #expect(back.resultText == source)
}

@Test
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
            if (try? DocumentEditPlanner.prepare(edits + [candidate], in: source)) != nil {
                edits.append(candidate)
            }
            cursor = start + len + (Bool.random(using: &generator) ? 0 : 1)
        }
        guard let plan = try DocumentEditPlanner.prepare(edits, in: source) else { continue }
        let back = try #require(
            try DocumentEditPlanner.prepare(plan.inverseEdits, in: plan.resultText),
            "seed 0xC0FFEE iteration \(iteration): inverse of \(edits) on \(source.debugDescription)"
        )
        #expect(back.resultText == source, "seed 0xC0FFEE iteration \(iteration)")
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
