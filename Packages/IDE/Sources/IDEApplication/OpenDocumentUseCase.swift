import IDEDomain

public enum OpenDocumentError: Error, Equatable, Sendable {
    /// A Save As is giving this name to another document right now.
    case beingSavedElsewhere(path: String)
}

public struct OpenedDocument: Sendable {
    public let session: DocumentSession
    /// False when the file was already open and its existing session is returned.
    public let isNew: Bool
}

/// Opens a file as a document, once per file.
@MainActor
public final class OpenDocumentUseCase {
    public static let defaultMaximumBytes = 100 * 1024 * 1024

    private let store: any DocumentFileStore
    private let registry: DocumentRegistry
    private let maximumBytes: Int
    private let makeSession: @MainActor (LoadedFile) -> DocumentSession

    /// `makeSession` is the platform's part: it builds the editor over `file.text` and returns
    /// a session created with `DocumentSession(loaded:backend:)`.
    public init(
        store: any DocumentFileStore, registry: DocumentRegistry,
        maximumBytes: Int = OpenDocumentUseCase.defaultMaximumBytes,
        makeSession: @escaping @MainActor (LoadedFile) -> DocumentSession
    ) {
        self.store = store
        self.registry = registry
        self.maximumBytes = maximumBytes
        self.makeSession = makeSession
    }

    public func execute(path: String) async throws -> OpenedDocument {
        let canonical = DocumentPath.canonical(path)
        if let existing = registry.session(atPath: canonical) {
            return OpenedDocument(session: existing, isNew: false)
        }
        guard !registry.isReserved(path: canonical) else {
            throw OpenDocumentError.beingSavedElsewhere(path: canonical)
        }
        let file = try await store.read(path: canonical, maximumBytes: maximumBytes)
        // A cancelled open or a closed workspace must not leave a late document behind.
        try Task.checkCancellation()
        // A Save As may have taken the name while the file was being read.
        guard !registry.isReserved(path: canonical) else {
            throw OpenDocumentError.beingSavedElsewhere(path: canonical)
        }
        // The same file may have been opened while this read was in flight, or this path may be
        // another name (hard link) of a file that is already open.
        if let existing = registry.session(atPath: canonical)
            ?? registry.session(withFileID: file.revision.fileID) {
            return OpenedDocument(session: existing, isNew: false)
        }
        let session = makeSession(file)
        precondition(session.path == file.path, "makeSession must create the session from the loaded file")
        registry.register(session)
        return OpenedDocument(session: session, isNew: true)
    }
}
