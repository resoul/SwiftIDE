import IDEApplication
import IDEDomain
import IDETestSupport
import Testing

/// Reads the file at once, but hands the text over only when released: the file is "being read"
/// for as long as a test needs.
private actor SlowReadStore: DocumentFileStore {
    let inner: MemoryDocumentFileStore
    private var gate: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?
    private var hasStarted = false

    init(_ inner: MemoryDocumentFileStore) { self.inner = inner }

    func read(path: String, maximumBytes: Int) async throws -> LoadedFile {
        let file = try await inner.read(path: path, maximumBytes: maximumBytes)
        hasStarted = true
        started?.resume()
        await withCheckedContinuation { gate = $0 }
        return file
    }

    func write(_ snapshot: DocumentSnapshot, expecting: SaveExpectation) async throws -> FileRevision {
        try await inner.write(snapshot, expecting: expecting)
    }

    func currentRevision(path: String, assumingUnchangedFrom known: FileRevision?) async throws -> FileRevision? {
        try await inner.currentRevision(path: path, assumingUnchangedFrom: known)
    }

    func waitUntilReading() async {
        if hasStarted { return }
        await withCheckedContinuation { started = $0 }
    }

    func release() { gate?.resume(); gate = nil }
}

@Test @MainActor
func aSaveAsWhileTheOldFileIsBeingReadDiscardsThatRead() async throws {
    let files = MemoryDocumentFileStore(contents: ["/w/Old.swift": "old\n"])
    let slow = SlowReadStore(files)
    let registry = DocumentRegistry()
    let open = OpenDocumentUseCase(store: files, registry: registry) { file in
        DocumentSession(loaded: file, backend: StringDocumentBackend(loadedText: file.text))
    }
    let session = try await open.execute(path: "/w/Old.swift").session

    let reloading = Task { @MainActor in try await ReloadDocumentUseCase(store: slow).execute(document: session) }
    await slow.waitUntilReading()
    // The document moves to another file while the old one is being read.
    _ = try await SaveDocumentUseCase(store: files).saveAs(
        document: session, to: "/w/New.swift", target: .newFile, registry: registry
    )
    await slow.release()

    await #expect(throws: DocumentError.pathChanged) { try await reloading.value }
    #expect(session.path == "/w/New.swift", "it stays where it was moved")
    #expect(session.text == "old\n" && !session.isDirty)
}
