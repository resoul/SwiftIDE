import IDEApplication
import IDEDomain
import IDETestSupport
import Testing

private enum TestStoreError: Error, Equatable {
    case writeFailed
}

/// Deterministic suspended I/O; tests need no sleeps or timing assumptions.
private actor ControlledFileStore: DocumentFileStore {
    private var pending: CheckedContinuation<FileRevision, any Error>?
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var hasStarted = false
    private(set) var written: DocumentSnapshot?

    func read(path: String, maximumBytes: Int) async throws -> LoadedFile { throw FileStoreError.notFound }

    func write(_ snapshot: DocumentSnapshot, expecting: SaveExpectation) async throws -> FileRevision {
        try await withCheckedThrowingContinuation { continuation in
            pending = continuation
            written = snapshot
            hasStarted = true
            for waiter in startedWaiters { waiter.resume() }
            startedWaiters.removeAll()
        }
    }

    func waitUntilStarted() async {
        if hasStarted { return }
        await withCheckedContinuation { startedWaiters.append($0) }
    }

    func finish(failing: Bool = false) {
        guard let continuation = pending else {
            preconditionFailure("finish must follow waitUntilStarted")
        }
        pending = nil
        if failing {
            continuation.resume(throwing: TestStoreError.writeFailed)
        } else {
            continuation.resume(returning: .stub(Int64(written?.version ?? 1)))
        }
    }
}

@Test @MainActor
func successfulSavePersistsTextAndClearsDirtyFlag() async throws {
    let store = MemoryDocumentFileStore()
    let save = SaveDocumentUseCase(store: store)
    let document = DocumentSession(path: "Main.swift", backend: StringDocumentBackend(loadedText: "old"))
    try document.replaceText("new", expectedVersion: 0)

    let receipt = try await save.execute(document: document)

    #expect(await store.text(at: document.path) == "new")
    #expect(receipt.savedVersion == 1)
    #expect(receipt.isCurrent)
    #expect(!document.isDirty)
}

@Test @MainActor
func editsDuringSaveRemainDirty() async throws {
    let store = ControlledFileStore()
    let save = SaveDocumentUseCase(store: store)
    let document = DocumentSession(path: "Main.swift", backend: StringDocumentBackend(loadedText: "original"))
    try document.replaceText("version one", expectedVersion: 0)
    let task = Task { try await save.execute(document: document) }
    await store.waitUntilStarted()

    try document.replaceText("version two", expectedVersion: 1)
    await store.finish()
    let receipt = try await task.value

    #expect(await store.written?.text == "version one")
    #expect(document.text == "version two")
    #expect(document.savedVersion == 1)
    #expect(document.version == 2)
    #expect(document.isDirty)
    #expect(!receipt.isCurrent)
}

@Test @MainActor
func failedSaveKeepsDirtyStateAndAllowsRetry() async throws {
    let store = ControlledFileStore()
    let save = SaveDocumentUseCase(store: store)
    let document = DocumentSession(path: "Main.swift", backend: StringDocumentBackend(loadedText: "old"))
    try document.replaceText("new", expectedVersion: 0)
    let first = Task { try await save.execute(document: document) }
    await store.waitUntilStarted()
    await store.finish(failing: true)
    do {
        _ = try await first.value
        Issue.record("Expected failed save")
    } catch {
        #expect(error as? TestStoreError == .writeFailed)
    }
    #expect(document.savedVersion == 0)
    #expect(document.isDirty)

    // Retry with the same use-case instance verifies its in-flight guard was released.
    // ControlledFileStore.hasStarted stays true, so signal a fresh write via a new
    // task handshake by resetting the fake below.
    await store.resetStartedSignal()
    let retry = Task { try await save.execute(document: document) }
    await store.waitUntilStarted()
    await store.finish()
    _ = try await retry.value
    #expect(!document.isDirty)
}

private extension ControlledFileStore {
    func resetStartedSignal() {
        precondition(pending == nil)
        hasStarted = false
    }
}

@Test @MainActor
func concurrentSaveOfSameDocumentIsRejected() async throws {
    let store = ControlledFileStore()
    let save = SaveDocumentUseCase(store: store)
    let document = DocumentSession(path: "Main.swift", backend: StringDocumentBackend(loadedText: "old"))
    try document.replaceText("new", expectedVersion: 0)
    let first = Task { try await save.execute(document: document) }
    await store.waitUntilStarted()

    do {
        _ = try await save.execute(document: document)
        Issue.record("Expected saveInProgress")
    } catch {
        #expect(error as? SaveError == .saveInProgress(document.id))
    }
    await store.finish()
    _ = try await first.value
    #expect(!document.isDirty)
}

@Test @MainActor
func staleEditDoesNotMutateDocument() throws {
    let document = DocumentSession(path: "Main.swift", backend: StringDocumentBackend(loadedText: "old"))
    try document.replaceText("current", expectedVersion: 0)
    let before = document.snapshot()
    #expect(throws: DocumentError.staleVersion(expected: 0, actual: 1)) {
        try document.replaceText("stale", expectedVersion: 0)
    }
    #expect(document.snapshot() == before)
}

@Test @MainActor
func byteIdenticalEditIsNoOpButUnicodeNormalizationIsAnEdit() throws {
    let document = DocumentSession(path: "Main.swift", backend: StringDocumentBackend(loadedText: "é"))
    try document.replaceText("é", expectedVersion: 0)
    #expect(document.version == 0)
    #expect(!document.isDirty)

    try document.replaceText("e\u{301}", expectedVersion: 0)
    #expect(document.version == 1)
    #expect(Array(document.text.utf8) == [0x65, 0xCC, 0x81])
    #expect(document.isDirty)
}
