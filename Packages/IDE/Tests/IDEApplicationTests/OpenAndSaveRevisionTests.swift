import IDEApplication
import IDEDomain
import IDETestSupport
import Testing

@MainActor
private final class Harness {
    let store: MemoryDocumentFileStore
    let registry = DocumentRegistry()
    private(set) var created = 0
    var open: OpenDocumentUseCase!

    init(files: [String: String], store: MemoryDocumentFileStore? = nil, maximumBytes: Int = 1_000_000) {
        self.store = store ?? MemoryDocumentFileStore(contents: files)
        open = OpenDocumentUseCase(store: self.store, registry: registry, maximumBytes: maximumBytes) { [unowned self] file in
            created += 1

            return DocumentSession(loaded: file, backend: StringDocumentBackend(loadedText: file.text))
        }
    }
}

// MARK: Opening

@Test @MainActor
func openCreatesASessionFromTheLoadedFile() async throws {
    let h = Harness(files: ["/w/Main.swift": "let x = 1\r\n"])
    let opened = try await h.open.execute(path: "/w/Main.swift")
    #expect(opened.isNew)
    #expect(opened.session.text == "let x = 1\r\n")
    #expect(opened.session.path == "/w/Main.swift")
    #expect(opened.session.diskRevision != nil)
    #expect(!opened.session.isDirty)
    #expect(h.registry.openDocuments.count == 1)
}

@Test @MainActor
func openingTheSameFileAgainReturnsTheExistingSession() async throws {
    let h = Harness(files: ["/w/Main.swift": "a"])
    let first = try await h.open.execute(path: "/w/Main.swift")
    // Another spelling of the same path.
    let second = try await h.open.execute(path: "/w/./sub/../Main.swift")
    #expect(!second.isNew)
    #expect(second.session === first.session)
    #expect(h.created == 1)
}

@Test @MainActor
func simultaneousOpensOfOneFileProduceOneSession() async throws {
    let h = Harness(files: ["/w/Main.swift": "a"])
    async let one = h.open.execute(path: "/w/Main.swift")
    async let two = h.open.execute(path: "/w/Main.swift")
    let (a, b) = try await (one, two)
    #expect(a.session === b.session)
    #expect(h.created == 1)
    #expect([a.isNew, b.isNew].filter { $0 }.count == 1)
}

@Test @MainActor
func closedDocumentCanBeOpenedAgainFromDisk() async throws {
    let h = Harness(files: ["/w/Main.swift": "a"])
    let first = try await h.open.execute(path: "/w/Main.swift")
    h.registry.remove(first.session)
    await h.store.externallyWrite("b", at: "/w/Main.swift")
    let second = try await h.open.execute(path: "/w/Main.swift")
    #expect(second.isNew)
    #expect(second.session !== first.session)
    #expect(second.session.text == "b")
}

@Test @MainActor
func failedOrOversizedOpenRegistersNothing() async throws {
    let h = Harness(files: ["/w/Big.swift": String(repeating: "x", count: 100)], maximumBytes: 10)
    await #expect(throws: FileStoreError.tooLarge(size: 100, limit: 10)) {
        try await h.open.execute(path: "/w/Big.swift")
    }
    await #expect(throws: FileStoreError.notFound) { try await h.open.execute(path: "/w/Nope.swift") }
    #expect(h.registry.openDocuments.isEmpty)
    #expect(h.created == 0)
}

private actor GatedReadStore: DocumentFileStore {
    private var gate: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?
    private var hasStarted = false

    func read(path: String, maximumBytes: Int) async throws -> LoadedFile {
        hasStarted = true
        started?.resume()
        await withCheckedContinuation { gate = $0 }

        return LoadedFile(path: path, text: "late", encoding: .utf8, revision: .stub())
    }

    func write(_ snapshot: DocumentSnapshot, expecting: SaveExpectation) async throws -> FileRevision { .stub() }

    func waitUntilReading() async {
        if hasStarted { return }
        await withCheckedContinuation { started = $0 }
    }

    func release() { gate?.resume(); gate = nil }
}

@Test @MainActor
func cancelledOpenLeavesNoLateDocumentBehind() async throws {
    let store = GatedReadStore()
    let registry = DocumentRegistry()
    var created = 0
    let open = OpenDocumentUseCase(store: store, registry: registry) { file in
        created += 1

        return DocumentSession(loaded: file, backend: StringDocumentBackend(loadedText: file.text))
    }
    let task = Task { try await open.execute(path: "/w/Main.swift") }
    await store.waitUntilReading()
    task.cancel()
    await store.release()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(registry.openDocuments.isEmpty)
    #expect(created == 0)
}

@Test @MainActor
func encodingOfTheLoadedFileTravelsWithEverySnapshot() throws {
    let file = LoadedFile(path: "/w/Bom.swift", text: "a", encoding: .utf8WithBOM, revision: .stub())
    let session = DocumentSession(loaded: file, backend: StringDocumentBackend(loadedText: "a"))
    try session.replaceText("b", expectedVersion: 0)
    #expect(session.snapshot().encoding == .utf8WithBOM)
}

// MARK: Saving against revisions

@Test @MainActor
func saveUsesTheRevisionTheDocumentWasLoadedFromAndAdvancesIt() async throws {
    let h = Harness(files: ["/w/Main.swift": "old"])
    let save = SaveDocumentUseCase(store: h.store)
    let session = try await h.open.execute(path: "/w/Main.swift").session
    let loadedRevision = session.diskRevision

    try session.replaceText("one", expectedVersion: 0)
    _ = try await save.execute(document: session)
    #expect(session.diskRevision != loadedRevision)
    #expect(session.diskRevision == (await h.store.revision(at: "/w/Main.swift")))

    // A second save is based on the first one's result, so it does not conflict with itself.
    try session.replaceText("two", expectedVersion: 1)
    _ = try await save.execute(document: session)
    #expect(await h.store.text(at: "/w/Main.swift") == "two")
    #expect(!session.isDirty)
}

@Test @MainActor
func externalChangeMakesSaveFailWithConflictAndKeepsEverythingDirty() async throws {
    let h = Harness(files: ["/w/Main.swift": "old"])
    let save = SaveDocumentUseCase(store: h.store)
    let session = try await h.open.execute(path: "/w/Main.swift").session
    try session.replaceText("mine", expectedVersion: 0)
    await h.store.externallyWrite("theirs", at: "/w/Main.swift")

    do {
        _ = try await save.execute(document: session)
        Issue.record("Expected conflict")
    } catch FileStoreError.conflict(let current) {
        #expect(current != nil)
    }
    #expect(await h.store.text(at: "/w/Main.swift") == "theirs")
    #expect(session.isDirty)
    #expect(session.text == "mine")
    // The use case is usable again: the failed save did not hold the document.
    _ = try await save.execute(document: session, overwritingExternalChanges: true)
    #expect(await h.store.text(at: "/w/Main.swift") == "mine")
    #expect(!session.isDirty)
}

@Test @MainActor
func editsDuringSaveStayDirtyAndTheNextSaveBuildsOnTheNewRevision() async throws {
    let h = Harness(files: ["/w/Main.swift": "old"])
    let save = SaveDocumentUseCase(store: h.store)
    let session = try await h.open.execute(path: "/w/Main.swift").session
    try session.replaceText("one", expectedVersion: 0)
    let first = try await save.execute(document: session)
    try session.replaceText("two", expectedVersion: 1)
    #expect(first.isCurrent)
    #expect(session.isDirty)
    _ = try await save.execute(document: session)
    #expect(!session.isDirty)
}

// MARK: Reloading

@Test @MainActor
func reloadReplacesTextWithDiskContentAndLeavesTheDocumentClean() async throws {
    let h = Harness(files: ["/w/Main.swift": "old"])
    let reload = ReloadDocumentUseCase(store: h.store)
    let session = try await h.open.execute(path: "/w/Main.swift").session
    try session.replaceText("my unsaved edit", expectedVersion: 0)
    await h.store.externallyWrite("from disk", at: "/w/Main.swift")

    try await reload.execute(document: session)
    #expect(session.text == "from disk")
    #expect(!session.isDirty)
    #expect(session.diskRevision == (await h.store.revision(at: "/w/Main.swift")))
    // Saving after a reload does not conflict.
    try session.replaceText("next", expectedVersion: session.version)
    _ = try await SaveDocumentUseCase(store: h.store).execute(document: session)
    #expect(await h.store.text(at: "/w/Main.swift") == "next")
}

@Test @MainActor
func reloadOfUnchangedContentOnlyRefreshesTheRevision() async throws {
    let h = Harness(files: ["/w/Main.swift": "same"])
    let reload = ReloadDocumentUseCase(store: h.store)
    let session = try await h.open.execute(path: "/w/Main.swift").session
    await h.store.externallyWrite("same", at: "/w/Main.swift")
    try await reload.execute(document: session)
    #expect(session.version == 0)
    #expect(!session.isDirty)
    #expect(session.diskRevision == (await h.store.revision(at: "/w/Main.swift")))
}

@Test @MainActor
func reloadRefusesToDiscardInputTypedWhileTheFileWasBeingRead() async throws {
    let store = GatedReadStore()
    let session = DocumentSession(
        loaded: LoadedFile(path: "/w/Main.swift", text: "old", encoding: .utf8, revision: .stub()),
        backend: StringDocumentBackend(loadedText: "old")
    )
    let reload = ReloadDocumentUseCase(store: store)
    let task = Task { try await reload.execute(document: session) }
    await store.waitUntilReading()
    // Typing lands while the read is in flight.
    try session.replaceText("typed meanwhile", expectedVersion: 0)
    await store.release()
    await #expect(throws: DocumentError.staleVersion(expected: 0, actual: 1)) { try await task.value }
    #expect(session.text == "typed meanwhile")
    #expect(session.isDirty)
}
