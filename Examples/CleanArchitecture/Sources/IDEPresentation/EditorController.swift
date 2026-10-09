import IDEApplication

@MainActor
public final class EditorController {
    private let document: DocumentSession
    private let saveDocument: SaveDocumentUseCase

    public var text: String { document.text }
    public var isDirty: Bool { document.isDirty }

    public init(document: DocumentSession, saveDocument: SaveDocumentUseCase) {
        self.document = document
        self.saveDocument = saveDocument
    }

    public func replaceText(_ text: String) throws {
        try document.replaceText(text, expectedVersion: document.version)
    }

    public func save() async throws -> SaveReceipt {
        try await saveDocument.execute(document: document)
    }
}
