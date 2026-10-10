import Foundation
import IDEApplication
import IDEDomain
import IDETestSupport
import Testing

/// A document opened from an in-memory file, with a recovery coordinator driven by a hand clock.
@MainActor
private struct Setup {
    let files: MemoryDocumentFileStore
    let registry = DocumentRegistry()
    let session: DocumentSession
    let recovery = MemoryRecoveryStore()
    let clock = ManualDelayClock()
    let coordinator: RecoveryCoordinator
    let key: RecoveryKey

    init(
        path: String = "/w/Main.swift",
        text: String = "let a = 1\n",
        policy: RecoveryPolicy = .standard,
        scratch: Bool = false
    ) async throws {
        files = MemoryDocumentFileStore(contents: [path: text])
        if scratch {
            session = DocumentSession(path: "Untitled.swift", backend: StringDocumentBackend(loadedText: text), isUntitled: true)
            key = .scratch(session.id)
        } else {
            let open = OpenDocumentUseCase(store: files, registry: registry) { file in
                DocumentSession(loaded: file, backend: StringDocumentBackend(loadedText: file.text))
            }
            session = try await open.execute(path: path).session
            key = .file(atPath: path)
        }

        coordinator = RecoveryCoordinator(session: session, store: recovery, policy: policy, clock: clock)
    }

    func edit(_ text: String, at location: Int = 0) throws {
        try session.apply(
            [DocumentEdit(range: UTF16TextRange(location: location, length: 0), replacement: text)],
            expectedVersion: session.version
        )
    }

    func save() async throws {
        _ = try await SaveDocumentUseCase(store: files).execute(document: session)
    }

    /// Lets the timer task, the queue and the store run, without moving the clock.
    func settle() async {
        for _ in 0..<30 { await Task.yield() }
        await coordinator.waitUntilIdle()
    }

    func advance(_ seconds: Double) async {
        // The timer task must have started waiting before the time moves, as it would in life.
        for _ in 0..<30 { await Task.yield() }
        clock.advance(by: .milliseconds(Int(seconds * 1_000)))
        await settle()
    }
}

// MARK: When text is written

@Test @MainActor
func aCleanDocumentWritesNothing() async throws {
    let s = try await Setup()
    await s.advance(60)
    #expect(await s.recovery.operations.isEmpty)
}

@Test @MainActor
func anEditIsWrittenOnlyOnceTheDebounceHasPassed() async throws {
    let s = try await Setup()
    try s.edit("// new\n")
    await s.advance(1.9)
    #expect(await s.recovery.operations.isEmpty, "not yet")

    await s.advance(0.2)
    let record = try #require(await s.recovery.record(for: s.key))
    #expect(record.text == "// new\nlet a = 1\n")
    #expect(record.path == "/w/Main.swift" && record.title == "Main.swift")
    #expect(record.baseRevision == s.session.diskRevision, "what a later save is judged against")
    #expect(record.encoding == .utf8)
}

@Test @MainActor
func editsInsideTheDebounceAreWrittenOnceWithTheFinalText() async throws {
    let s = try await Setup()
    try s.edit("a")
    await s.advance(1)
    try s.edit("b")
    await s.advance(1)
    try s.edit("c")
    await s.advance(1.9)
    #expect(await s.recovery.operations.isEmpty, "each edit restarts the wait")
    await s.advance(0.2)
    #expect(await s.recovery.operations == [.write(s.key, text: "cbalet a = 1\n")])
}

@Test @MainActor
func steadyTypingIsStillWrittenAfterTheMaximumDelay() async throws {
    let s = try await Setup()
    for second in 1...9 {
        try s.edit("x")
        await s.advance(1)
        #expect(await s.recovery.operations.isEmpty, "second \(second): still inside the maximum delay")
    }
    try s.edit("x")
    await s.advance(1)   // ten seconds since the first unsaved edit
    let writes = await s.recovery.operations
    #expect(writes.count == 1, "written although there was never a pause")
    if case .write(_, let text)? = writes.first { #expect(text.hasPrefix("xxxxxxxxxx")) }
}

// MARK: When a record goes away

@Test @MainActor
func savingRemovesTheRecord() async throws {
    let s = try await Setup()
    try s.edit("x")
    await s.advance(2)
    #expect(await s.recovery.keys == [s.key])

    try await s.save()
    await s.settle()
    #expect(await s.recovery.keys.isEmpty)
    #expect(await s.recovery.operations.last == .remove(s.key))
}

@Test @MainActor
func aDocumentThatIsEditedAgainAfterASaveIsProtectedAgain() async throws {
    let s = try await Setup()
    try s.edit("x")
    await s.advance(2)
    try await s.save()
    await s.settle()
    try s.edit("y")
    await s.advance(2)
    #expect(await s.recovery.record(for: s.key)?.text == "yxlet a = 1\n")
}

@Test @MainActor
func aSaveCancelsTheWaitingWrite() async throws {
    let s = try await Setup()
    try s.edit("x")
    await s.advance(1)
    try await s.save()
    await s.settle()
    await s.advance(5)
    #expect(await s.recovery.operations.filter { if case .write = $0 { true } else { false } }.isEmpty,
            "the text is on disk: nothing is written for it")
}

@Test @MainActor
func saveAsMovesTheProtectionToTheNewName() async throws {
    let s = try await Setup(path: "/w/Old.swift")
    try s.edit("x")
    await s.advance(2)
    #expect(await s.recovery.keys == [.file(atPath: "/w/Old.swift")])

    _ = try await SaveDocumentUseCase(store: s.files).saveAs(
        document: s.session,
        to: "/w/New.swift",
        target: .newFile,
        registry: s.registry
    )
    await s.settle()
    #expect(await s.recovery.keys.isEmpty, "saved under the new name: nothing unsaved is left")

    try s.edit("y")
    await s.advance(2)
    #expect(await s.recovery.keys == [.file(atPath: "/w/New.swift")], "and the old name is not resurrected")
}

@Test @MainActor
func theRecordKeepsItsOrderAgainstALaterRemoval() async throws {
    let s = try await Setup()
    await s.recovery.hold()
    try s.edit("x")
    for _ in 0..<30 { await Task.yield() }
    s.clock.advance(by: .seconds(2))
    for _ in 0..<30 { await Task.yield() }   // the write is queued and waiting inside the store
    try await s.save()
    for _ in 0..<30 { await Task.yield() }   // the removal is queued behind it
    await s.recovery.release()
    await s.settle()
    #expect(await s.recovery.keys.isEmpty, "the slow write must not land after the removal")
    #expect(await s.recovery.operations == [.write(s.key, text: "xlet a = 1\n"), .remove(s.key)])
}

// MARK: Other kinds of documents

@Test @MainActor
func aDocumentWithoutAFileIsKeptUnderItsOwnKeyWithoutAPath() async throws {
    let s = try await Setup(text: "scratch\n", scratch: true)
    try s.edit("x")
    await s.advance(2)
    let record = try #require(await s.recovery.record(for: s.key))
    #expect(record.path == nil && record.title == "Untitled")
    #expect(record.baseRevision == nil)
    #expect(s.key.rawValue.hasPrefix("scratch:"))
}

@Test @MainActor
func aDocumentOverTheSizeLimitIsNotKeptAndSaysSo() async throws {
    let s = try await Setup(text: "abc", policy: RecoveryPolicy(maximumUTF16Length: 100))
    try s.edit("x")
    await s.advance(2)
    #expect(await s.recovery.keys == [s.key])
    #expect(s.coordinator.status == .protecting)

    try s.edit(String(repeating: "y", count: 200))
    await s.advance(2)
    #expect(await s.recovery.keys.isEmpty, "a record of an older text would mislead more than help")
    #expect(s.coordinator.status == .tooLarge)

    try s.session.apply(
        [DocumentEdit(range: UTF16TextRange(location: 0, length: 200), replacement: "")],
        expectedVersion: s.session.version
    )
    await s.advance(2)
    #expect(await s.recovery.keys == [s.key])
    #expect(s.coordinator.status == .protecting)
}

@Test @MainActor
func textIsNotCopiedWhileAnInputMethodHoldsMarkedText() async throws {
    let s = try await Setup()
    try s.edit("x")
    s.session.compositionDidChange(.began)
    await s.advance(2)
    await s.advance(2)
    #expect(await s.recovery.operations.isEmpty, "marked text is not part of the document yet")

    s.session.compositionDidChange(.ended)
    await s.advance(2)
    #expect(await s.recovery.keys == [s.key])
}

// MARK: Failure, flushing and ending

@Test @MainActor
func aFailedWriteIsReportedAndTriedAgainAfterTheNextEdit() async throws {
    let s = try await Setup()
    await s.recovery.setFailingWrites(true)
    try s.edit("x")
    await s.advance(2)
    guard case .failing = s.coordinator.status else {
        Issue.record("expected a failing status, got \(s.coordinator.status)")

        return
    }

    await s.recovery.setFailingWrites(false)
    try s.edit("y")
    await s.advance(2)
    #expect(await s.recovery.record(for: s.key)?.text == "yxlet a = 1\n")
    #expect(s.coordinator.status == .protecting)
}

@Test @MainActor
func flushWritesAtOnceWithoutWaiting() async throws {
    let s = try await Setup()
    try s.edit("x")
    await s.coordinator.flush()
    #expect(await s.recovery.record(for: s.key)?.text == "xlet a = 1\n")
    #expect(s.clock.sleeperCount == 0, "the waiting write was replaced by this one")
}

@Test @MainActor
func flushOfACleanDocumentDoesNothing() async throws {
    let s = try await Setup()
    await s.coordinator.flush()
    #expect(await s.recovery.operations.isEmpty)
}

@Test @MainActor
func theSameVersionIsNotWrittenTwice() async throws {
    let s = try await Setup()
    try s.edit("x")
    await s.coordinator.flush()
    await s.coordinator.flush()
    await s.advance(5)
    #expect(await s.recovery.operations.count == 1)
}

@Test @MainActor
func discardRemovesTheRecordAndStopsAnyFurtherWriting() async throws {
    let s = try await Setup()
    try s.edit("x")
    await s.advance(2)
    await s.coordinator.discard()
    #expect(await s.recovery.keys.isEmpty)

    try s.edit("y")
    await s.advance(5)
    #expect(await s.recovery.keys.isEmpty, "the user chose to drop these changes")
}

@Test @MainActor
func aCoordinatorThatWasReleasedWritesNothingMore() async throws {
    let files = MemoryDocumentFileStore(contents: ["/w/A.swift": "a"])
    let registry = DocumentRegistry()
    let open = OpenDocumentUseCase(store: files, registry: registry) { file in
        DocumentSession(loaded: file, backend: StringDocumentBackend(loadedText: file.text))
    }
    let session = try await open.execute(path: "/w/A.swift").session
    let store = MemoryRecoveryStore()
    let clock = ManualDelayClock()
    var coordinator: RecoveryCoordinator? = RecoveryCoordinator(session: session, store: store, clock: clock)
    try session.replaceText("b", expectedVersion: 0)
    for _ in 0..<30 { await Task.yield() }
    coordinator = nil
    clock.advance(by: .seconds(30))
    for _ in 0..<30 { await Task.yield() }
    #expect(await store.operations.isEmpty)
    _ = coordinator
}

/// A file store that lets a test type into the document while a write is in progress.
private struct TypingDuringWrite: DocumentFileStore {
    let base: MemoryDocumentFileStore
    let whileWriting: @Sendable () async -> Void

    func read(path: String, maximumBytes: Int) async throws -> LoadedFile {
        try await base.read(path: path, maximumBytes: maximumBytes)
    }

    func write(_ snapshot: DocumentSnapshot, expecting: SaveExpectation) async throws -> FileRevision {
        await whileWriting()

        return try await base.write(snapshot, expecting: expecting)
    }

    func currentRevision(path: String, assumingUnchangedFrom known: FileRevision?) async throws -> FileRevision? {
        try await base.currentRevision(path: path, assumingUnchangedFrom: known)
    }
}

@Test @MainActor
func textTypedWhileSavingUnderANewNameIsKeptOnlyUnderTheNewName() async throws {
    let s = try await Setup(path: "/w/Old.swift")
    try s.edit("x")
    await s.advance(2)
    #expect(await s.recovery.keys == [.file(atPath: "/w/Old.swift")])

    let session = s.session
    let store = TypingDuringWrite(base: s.files) {
        await MainActor.run {
            try? session.apply(
                [DocumentEdit(range: UTF16TextRange(location: 0, length: 0), replacement: "typed ")],
                expectedVersion: session.version
            )
        }
    }
    _ = try await SaveDocumentUseCase(store: store).saveAs(
        document: s.session,
        to: "/w/New.swift",
        target: .newFile,
        registry: s.registry
    )
    #expect(s.session.isDirty, "text typed during the write is not saved")
    await s.advance(2)
    #expect(await s.recovery.keys == [.file(atPath: "/w/New.swift")], "the old name is gone, the new one holds the newer text")
    #expect(await s.recovery.record(for: .file(atPath: "/w/New.swift"))?.text.hasPrefix("typed ") == true)
}

// MARK: Is the text safe?

@Test @MainActor
func flushSaysWhetherTheUnsavedTextIsNowInTheStore() async throws {
    let s = try await Setup()
    #expect(await s.coordinator.flush() == .nothingUnsaved, "nothing unsaved: nothing to keep")

    try s.edit("// new\n")
    #expect(await s.coordinator.flush() == .written(s.key, version: s.session.version))
    #expect(await s.recovery.record(for: s.key)?.text == "// new\nlet a = 1\n")
}

@Test @MainActor
func flushSaysNoWhenTheWriteFailed() async throws {
    let s = try await Setup()
    await s.recovery.setFailingWrites(true)
    try s.edit("// new\n")
    #expect(await s.coordinator.flush() == nil)
    #expect(await s.recovery.keys.isEmpty)
}

@Test @MainActor
func flushSaysNoWhenTheDocumentIsTooLargeToKeep() async throws {
    let s = try await Setup(policy: RecoveryPolicy(debounce: .seconds(2), maximumDelay: .seconds(10), maximumUTF16Length: 10))
    try s.edit("// something longer than the limit\n")
    #expect(await s.coordinator.flush() == nil)
    #expect(await s.recovery.keys.isEmpty)
}

@Test @MainActor
func flushSaysNoAfterAFailedWriteFollowedAGoodOneThatWasRemoved() async throws {
    let s = try await Setup()
    try s.edit("// new\n")
    #expect(await s.coordinator.flush() != nil)
    try await s.save()
    await s.settle()
    try s.edit("// again\n")
    await s.recovery.setFailingWrites(true)
    #expect(await s.coordinator.flush() == nil, "the record of the earlier text was removed when it was saved")
}

// MARK: Withdrawing for a quit

@Test @MainActor
func withdrawingRemovesTheRecordAndKeepsItOffUntilResumed() async throws {
    let s = try await Setup()
    try s.edit("// new\n")
    #expect(await s.coordinator.flush() != nil)
    #expect(await s.recovery.keys == [s.key])

    await s.coordinator.withdraw()
    #expect(await s.recovery.keys.isEmpty)

    // Typing on, with the clock running, writes nothing while it is withdrawn.
    try s.edit("// more\n")
    await s.advance(30)
    #expect(await s.recovery.keys.isEmpty)

    s.coordinator.resume()
    await s.advance(3)
    #expect(await s.recovery.record(for: s.key)?.text == "// more\n// new\nlet a = 1\n")
}

@Test @MainActor
func resumingWithoutNewEditsWritesTheUnsavedTextAgain() async throws {
    let s = try await Setup()
    try s.edit("// new\n")
    #expect(await s.coordinator.flush() != nil)
    await s.coordinator.withdraw()
    s.coordinator.resume()
    await s.advance(3)
    #expect(await s.recovery.record(for: s.key)?.text == "// new\nlet a = 1\n")
}

@Test @MainActor
func flushSaysNoWhenTheLatestWriteFailedEvenThoughAnOlderRecordExists() async throws {
    let s = try await Setup()
    try s.edit("// one\n")
    #expect(await s.coordinator.flush() != nil)
    try s.edit("// two\n")
    await s.recovery.setFailingWrites(true)
    #expect(await s.coordinator.flush() == nil, "the record holds the older text, not this one")
}

@Test @MainActor
func theReceiptNamesTheVersionThatWasWrittenNotTheOneTypedWhileItWasBeingWritten() async throws {
    let s = try await Setup()
    try s.edit("// one\n")
    let written = s.session.version
    await s.recovery.hold()
    let flushing = Task { @MainActor in await s.coordinator.flush() }
    for _ in 0..<40 { await Task.yield() }   // the write has its text and waits in the store
    try s.edit("// two\n")
    await s.recovery.release()
    let receipt = await flushing.value

    #expect(receipt == .written(s.key, version: written), "version \(written) is in the store, not \(s.session.version)")
    #expect(await s.recovery.record(for: s.key)?.text == "// one\nlet a = 1\n")
    #expect(s.session.version > written)
}
