import Darwin
import Foundation
import FileSystemInfrastructure
import IDEApplication
import IDEDomain
import Testing

@MainActor
private final class TextBackend: DocumentEditingBackend {
    private(set) var text: String
    init(_ text: String) { self.text = text }
    func commit(_ plan: PreparedDocumentEdit) { text = plan.resultText }
}

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
            DocumentSession(loaded: file, backend: TextBackend(file.text))
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
