import IDEApplication
import IDEDomain
import IDETestSupport
import Testing

@MainActor
private func untitled(_ text: String = "scratch") -> DocumentSession {
    DocumentSession(path: "Untitled.swift", backend: StringDocumentBackend(loadedText: text), isUntitled: true)
}

@MainActor
private func opened(_ path: String, _ text: String, in store: MemoryDocumentFileStore, registry: DocumentRegistry) async throws -> DocumentSession {
    let open = OpenDocumentUseCase(store: store, registry: registry) { file in
        DocumentSession(loaded: file, backend: StringDocumentBackend(loadedText: file.text))
    }

    return try await open.execute(path: path).session
}

@Test @MainActor
func aScratchDocumentSavedUnderANameBecomesThatFile() async throws {
    let store = MemoryDocumentFileStore()
    let registry = DocumentRegistry()
    let save = SaveDocumentUseCase(store: store)
    let session = untitled("print(1)")
    try session.replaceText("print(2)", expectedVersion: 0)

    let receipt = try await save.saveAs(
        document: session,
        to: "/w/New.swift",
        target: .newFile,
        registry: registry
    )

    #expect(receipt.savedVersion == 1 && receipt.isCurrent)
    #expect(session.path == "/w/New.swift")
    #expect(!session.isUntitled)
    #expect(!session.isDirty)
    #expect(await store.text(at: "/w/New.swift") == "print(2)")
    #expect(registry.session(atPath: "/w/New.swift") === session)
    // From now on it is an ordinary document: the next save goes to the same file, no conflict.
    try session.replaceText("print(3)", expectedVersion: 1)
    _ = try await save.execute(document: session)
    #expect(await store.text(at: "/w/New.swift") == "print(3)")
}

@Test @MainActor
func aScratchDocumentCannotBeSavedWithoutAName() async throws {
    let save = SaveDocumentUseCase(store: MemoryDocumentFileStore())
    let session = untitled()
    await #expect(throws: SaveError.untitled(session.id)) { try await save.execute(document: session) }
}

@Test @MainActor
func saveAsLeavesTheOriginalFileAndMovesTheDocument() async throws {
    let store = MemoryDocumentFileStore(contents: ["/w/Old.swift": "old"])
    let registry = DocumentRegistry()
    let save = SaveDocumentUseCase(store: store)
    let session = try await opened("/w/Old.swift", "old", in: store, registry: registry)
    try session.replaceText("changed", expectedVersion: 0)

    _ = try await save.saveAs(document: session, to: "/w/Copy.swift", target: .newFile, registry: registry)

    #expect(await store.text(at: "/w/Old.swift") == "old", "the original is not touched")
    #expect(await store.text(at: "/w/Copy.swift") == "changed")
    #expect(session.path == "/w/Copy.swift" && !session.isDirty)
    #expect(registry.session(atPath: "/w/Old.swift") == nil, "the old name is free again")
    #expect(registry.session(atPath: "/w/Copy.swift") === session)
    #expect(registry.openDocuments.count == 1)
}

@Test @MainActor
func aNameThatAppearedMeanwhileIsAConflictAndNothingChanges() async throws {
    let store = MemoryDocumentFileStore(contents: ["/w/Taken.swift": "someone else's"])
    let registry = DocumentRegistry()
    let save = SaveDocumentUseCase(store: store)
    let session = untitled("mine")
    try session.replaceText("mine!", expectedVersion: 0)

    do {
        _ = try await save.saveAs(document: session, to: "/w/Taken.swift", target: .newFile, registry: registry)
        Issue.record("Expected conflict")
    } catch FileStoreError.conflict {
    }
    #expect(await store.text(at: "/w/Taken.swift") == "someone else's")
    #expect(session.isUntitled && session.path == "Untitled.swift" && session.isDirty)
    #expect(registry.openDocuments.isEmpty)
}

@Test @MainActor
func replacingAnExistingFileNeedsTheUsersExplicitAnswer() async throws {
    let store = MemoryDocumentFileStore(contents: ["/w/Taken.swift": "old"])
    let registry = DocumentRegistry()
    let save = SaveDocumentUseCase(store: store)
    let session = untitled("new")
    try session.replaceText("new!", expectedVersion: 0)

    let confirmed = try #require(await store.revision(at: "/w/Taken.swift"))
    _ = try await save.saveAs(document: session, to: "/w/Taken.swift", target: .replacing(confirmed), registry: registry)

    #expect(await store.text(at: "/w/Taken.swift") == "new!")
    #expect(session.path == "/w/Taken.swift" && !session.isDirty)
}

@Test @MainActor
func aFileOpenInAnotherWindowCannotBeTheTarget() async throws {
    let store = MemoryDocumentFileStore(contents: ["/w/Other.swift": "other"])
    let registry = DocumentRegistry()
    let save = SaveDocumentUseCase(store: store)
    _ = try await opened("/w/Other.swift", "other", in: store, registry: registry)
    let session = untitled("mine")
    try session.replaceText("mine!", expectedVersion: 0)

    let confirmed = try #require(await store.revision(at: "/w/Other.swift"))
    await #expect(throws: SaveError.targetOpenElsewhere(path: "/w/Other.swift")) {
        try await save.saveAs(document: session, to: "/w/Other.swift", target: .replacing(confirmed), registry: registry)
    }
    #expect(await store.text(at: "/w/Other.swift") == "other")
    #expect(session.isUntitled)
}

@Test @MainActor
func saveAsUnderTheDocumentsOwnNameIsAnOrdinarySave() async throws {
    let store = MemoryDocumentFileStore(contents: ["/w/Main.swift": "old"])
    let registry = DocumentRegistry()
    let save = SaveDocumentUseCase(store: store)
    let session = try await opened("/w/Main.swift", "old", in: store, registry: registry)
    try session.replaceText("new", expectedVersion: 0)

    _ = try await save.saveAs(document: session, to: "/w/./Main.swift", target: .newFile, registry: registry)

    #expect(await store.text(at: "/w/Main.swift") == "new")
    #expect(session.path == "/w/Main.swift" && !session.isDirty)
    #expect(registry.openDocuments.count == 1)
}

/// Suspends inside `write` until released, so a test can act while a save is in flight.
private actor GatedStore: DocumentFileStore {
    private var gate: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?
    private var hasStarted = false
    private(set) var written: [String: String] = [:]

    func read(path: String, maximumBytes: Int) async throws -> LoadedFile { throw FileStoreError.notFound }

    func write(_ snapshot: DocumentSnapshot, expecting: SaveExpectation) async throws -> FileRevision {
        hasStarted = true
        started?.resume()
        await withCheckedContinuation { gate = $0 }
        written[snapshot.path] = snapshot.text

        return .stub(Int64(snapshot.version))
    }

    func waitUntilWriting() async {
        if hasStarted { return }
        await withCheckedContinuation { started = $0 }
    }

    func release() { gate?.resume(); gate = nil }
}

@Test @MainActor
func textTypedWhileSavingAsStaysUnsaved() async throws {
    // The same rule as for Save: the write covers the text it captured, not what came after.
    let store = GatedStore()
    let registry = DocumentRegistry()
    let save = SaveDocumentUseCase(store: store)
    let session = untitled("one")
    try session.replaceText("two", expectedVersion: 0)
    let task = Task {
        try await save.saveAs(document: session, to: "/w/A.swift", target: .newFile, registry: registry)
    }
    await store.waitUntilWriting()
    try session.replaceText("three", expectedVersion: 1)
    await store.release()
    let receipt = try await task.value

    #expect(receipt.savedVersion == 1 && !receipt.isCurrent)
    #expect(session.path == "/w/A.swift", "the document moved to its new file")
    #expect(session.isDirty, "but the newest text is not in it yet")
    #expect(await store.written["/w/A.swift"] == "two")
}

@Test @MainActor
func saveAsDuringCompositionWaitsAndWritesTheFinishedText() async throws {
    let store = MemoryDocumentFileStore()
    let registry = DocumentRegistry()
    let save = SaveDocumentUseCase(store: store)
    let backend = StringDocumentBackend(loadedText: "abc")
    let session = DocumentSession(path: "Untitled.swift", backend: backend, isUntitled: true)
    backend.simulateComposition(.began)
    backend.simulateNativeEdit(UTF16TextRange(location: 3, length: 0), with: "é", origin: .composition)

    let task = Task { try await save.saveAs(document: session, to: "/w/C.swift", target: .newFile, registry: registry) }
    await Task.yield()
    #expect(backend.endCompositionRequests == 1)
    #expect(await store.text(at: "/w/C.swift") == nil)
    backend.simulateNativeEdit(UTF16TextRange(location: 3, length: 1), with: "ée", origin: .composition)
    backend.simulateComposition(.ended)
    _ = try await task.value
    #expect(await store.text(at: "/w/C.swift") == "abcée")
}

@Test @MainActor
func aSecondSaveAsWhileOneIsRunningIsRefused() async throws {
    let store = MemoryDocumentFileStore()
    let registry = DocumentRegistry()
    let save = SaveDocumentUseCase(store: store)
    let backend = StringDocumentBackend(loadedText: "abc")
    let session = DocumentSession(path: "Untitled.swift", backend: backend, isUntitled: true)
    backend.simulateComposition(.began)           // keeps the first one waiting
    let first = Task { try await save.saveAs(document: session, to: "/w/A.swift", target: .newFile, registry: registry) }
    await Task.yield()
    await #expect(throws: SaveError.saveInProgress(session.id)) {
        try await save.saveAs(document: session, to: "/w/B.swift", target: .newFile, registry: registry)
    }
    backend.simulateComposition(.ended)
    _ = try await first.value
    #expect(session.path == "/w/A.swift")
}

// MARK: The name is held for the whole operation, and consent is about one state of the file

@Test @MainActor
func theTargetNameIsHeldWhileSaveAsWaitsForAComposition() async throws {
    let store = MemoryDocumentFileStore(contents: ["/w/Target.swift": "original"])
    let registry = DocumentRegistry()
    let save = SaveDocumentUseCase(store: store)
    let open = OpenDocumentUseCase(store: store, registry: registry) { file in
        DocumentSession(loaded: file, backend: StringDocumentBackend(loadedText: file.text))
    }
    let backend = StringDocumentBackend(loadedText: "mine")
    let session = DocumentSession(path: "Untitled.swift", backend: backend, isUntitled: true)
    backend.simulateComposition(.began)
    let confirmed = try #require(await store.revision(at: "/w/Target.swift"))
    let saving = Task {
        try await save.saveAs(document: session, to: "/w/Target.swift", target: .replacing(confirmed), registry: registry)
    }
    await Task.yield()
    await Task.yield()

    // While Save As waits, another window tries to open that very file, and another document
    // tries to be saved under that name.
    await #expect(throws: OpenDocumentError.beingSavedElsewhere(path: "/w/Target.swift")) {
        try await open.execute(path: "/w/Target.swift")
    }
    let rival = DocumentSession(path: "Untitled.swift", backend: StringDocumentBackend(loadedText: "rival"), isUntitled: true)
    await #expect(throws: SaveError.targetBeingSaved(path: "/w/Target.swift")) {
        try await save.saveAs(document: rival, to: "/w/Target.swift", target: .replacing(confirmed), registry: registry)
    }
    #expect(registry.openDocuments.isEmpty)

    backend.simulateComposition(.ended)
    _ = try await saving.value

    #expect(await store.text(at: "/w/Target.swift") == "mine")
    #expect(registry.openDocuments.count == 1 && registry.openDocuments[0] === session)
    // The name is free of reservations again: opening it now finds the saved document.
    let again = try await open.execute(path: "/w/Target.swift")
    #expect(!again.isNew && again.session === session)
}

@Test @MainActor
func theReservationIsReleasedWhenSaveAsFails() async throws {
    let store = MemoryDocumentFileStore(contents: ["/w/Taken.swift": "theirs"])
    let registry = DocumentRegistry()
    let save = SaveDocumentUseCase(store: store)
    let session = untitled("mine")
    await #expect(throws: FileStoreError.self) {
        try await save.saveAs(document: session, to: "/w/Taken.swift", target: .newFile, registry: registry)
    }
    #expect(!registry.isReserved(path: "/w/Taken.swift"))
    // And another attempt can take it.
    let confirmed = try #require(await store.revision(at: "/w/Taken.swift"))
    _ = try await save.saveAs(document: session, to: "/w/Taken.swift", target: .replacing(confirmed), registry: registry)
    #expect(session.path == "/w/Taken.swift")
}

@Test @MainActor
func consentToReplaceCoversOnlyTheFileTheUserSaw() async throws {
    let store = MemoryDocumentFileStore(contents: ["/w/Taken.swift": "what the user saw"])
    let registry = DocumentRegistry()
    let save = SaveDocumentUseCase(store: store)
    let session = untitled("mine")
    let confirmed = try #require(await store.revision(at: "/w/Taken.swift"))

    // Someone else changes the file after the user agreed to replace it.
    await store.externallyWrite("changed after the user agreed", at: "/w/Taken.swift")

    do {
        _ = try await save.saveAs(document: session, to: "/w/Taken.swift", target: .replacing(confirmed), registry: registry)
        Issue.record("Expected conflict")
    } catch FileStoreError.conflict {
    }
    #expect(await store.text(at: "/w/Taken.swift") == "changed after the user agreed")
    #expect(session.isUntitled)
}

@Test @MainActor
func consentToReplaceDoesNotSurviveTheFileBeingDeleted() async throws {
    let store = MemoryDocumentFileStore(contents: ["/w/Gone.swift": "x"])
    let registry = DocumentRegistry()
    let save = SaveDocumentUseCase(store: store)
    let confirmed = try #require(await store.revision(at: "/w/Gone.swift"))
    // The memory store has no delete; a different name stands for "the file is no longer there".
    let session = untitled("mine")
    await #expect(throws: FileStoreError.conflict(current: nil)) {
        try await save.saveAs(document: session, to: "/w/Elsewhere.swift", target: .replacing(confirmed), registry: registry)
    }
    #expect(await store.text(at: "/w/Elsewhere.swift") == nil)
}
