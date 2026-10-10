import Darwin
import Foundation
import FileSystemInfrastructure
import IDEApplication
import IDEDomain
import IDETestSupport
import Testing

private func makeDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("swiftide-open-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

    return url
}

@MainActor
private struct Workspace {
    let store = AtomicDocumentFileStore()
    let registry = DocumentRegistry()
    let open: OpenDocumentUseCase

    init() {
        let store = store
        let registry = registry
        open = OpenDocumentUseCase(store: store, registry: registry) { file in
            DocumentSession(loaded: file, backend: StringDocumentBackend(loadedText: file.text))
        }
    }
}

@Test @MainActor
func hardLinkedPathsOpenAsOneDocument() async throws {
    let dir = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let a = dir.appendingPathComponent("A.swift").path
    let b = dir.appendingPathComponent("B.swift").path
    try Data("shared".utf8).write(to: URL(fileURLWithPath: a))
    #expect(link(a, b) == 0)

    let workspace = Workspace()
    let first = try await workspace.open.execute(path: a)
    let second = try await workspace.open.execute(path: b)
    #expect(first.isNew)
    #expect(!second.isNew, "the same file under another name is the same document")
    #expect(second.session === first.session)
    #expect(workspace.registry.openDocuments.count == 1)
}

@Test @MainActor
func aSavedFileKeepsItsIdentityEvenThoughItsInodeChanges() async throws {
    let dir = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let a = dir.appendingPathComponent("A.swift").path
    let b = dir.appendingPathComponent("B.swift").path
    try Data("shared".utf8).write(to: URL(fileURLWithPath: a))
    #expect(link(a, b) == 0)

    let workspace = Workspace()
    let save = SaveDocumentUseCase(store: workspace.store)
    let session = try await workspace.open.execute(path: a).session
    let inodeBefore = session.diskRevision?.fileID
    try session.replaceText("edited", expectedVersion: 0)
    _ = try await save.execute(document: session)
    #expect(session.diskRevision?.fileID != inodeBefore, "atomic replacement gives A a new inode")

    // A is still the same document, by path and by its new identity.
    let again = try await workspace.open.execute(path: a)
    #expect(!again.isNew && again.session === session)
    // B was detached from A by the atomic save: it is a different file now, and says "shared".
    let detached = try await workspace.open.execute(path: b)
    #expect(detached.isNew)
    #expect(detached.session !== session)
    #expect(detached.session.text == "shared")
}

// MARK: Save As on real files

@Test @MainActor
func aScratchDocumentSavedAsARealFileIsThenOpenedAsThatDocument() async throws {
    let dir = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let target = dir.appendingPathComponent("New.swift").path

    let workspace = Workspace()
    let save = SaveDocumentUseCase(store: workspace.store)
    let session = DocumentSession(
        path: "Untitled.swift",
        backend: StringDocumentBackend(loadedText: "let x = 1\r\n"),
        isUntitled: true
    )
    try session.replaceText("let x = 2\r\n", expectedVersion: 0)

    _ = try await save.saveAs(document: session, to: target, target: .newFile, registry: workspace.registry)

    #expect(try Data(contentsOf: URL(fileURLWithPath: target)) == Data("let x = 2\r\n".utf8))
    var info = stat()
    #expect(stat(target, &info) == 0)
    let mask = umask(0); umask(mask)
    #expect(info.st_mode & 0o777 == 0o666 & ~mask, "a new file gets the usual permissions")
    #expect(session.diskRevision?.fileID == FileIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino)))

    // Opening that file now finds the document, not a second copy.
    let again = try await workspace.open.execute(path: target)
    #expect(!again.isNew && again.session === session)

    // And the document keeps saving to it without a conflict.
    try session.replaceText("let x = 3\r\n", expectedVersion: 1)
    _ = try await save.execute(document: session)
    #expect(try Data(contentsOf: URL(fileURLWithPath: target)) == Data("let x = 3\r\n".utf8))
}

@Test @MainActor
func saveAsToAFileThatAppearedIsAConflictOnDiskAndReplacingIsExplicit() async throws {
    let dir = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let target = dir.appendingPathComponent("Taken.swift").path
    try Data("theirs".utf8).write(to: URL(fileURLWithPath: target))

    let workspace = Workspace()
    let save = SaveDocumentUseCase(store: workspace.store)
    let session = DocumentSession(path: "Untitled.swift", backend: StringDocumentBackend(loadedText: "mine"), isUntitled: true)

    do {
        _ = try await save.saveAs(document: session, to: target, target: .newFile, registry: workspace.registry)
        Issue.record("Expected conflict")
    } catch FileStoreError.conflict {
    }
    #expect(try Data(contentsOf: URL(fileURLWithPath: target)) == Data("theirs".utf8))
    #expect(session.isUntitled)
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["Taken.swift"], "no temporary file left")

    let confirmed = try #require(try AtomicDocumentFileStore.currentRevision(atPath: target))
    _ = try await save.saveAs(document: session, to: target, target: .replacing(confirmed), registry: workspace.registry)
    #expect(try Data(contentsOf: URL(fileURLWithPath: target)) == Data("mine".utf8))
    #expect(session.path == DocumentPath.canonical(target) && !session.isUntitled)
}
