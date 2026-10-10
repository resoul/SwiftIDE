import IDEDomain

/// Replaces the document text with what is on disk, as an ordinary undoable edit.
@MainActor
public final class ReloadDocumentUseCase {
    private let store: any DocumentFileStore
    private let maximumBytes: Int

    public init(store: any DocumentFileStore, maximumBytes: Int = OpenDocumentUseCase.defaultMaximumBytes) {
        self.store = store
        self.maximumBytes = maximumBytes
    }

    /// Fails with `staleVersion` if the user typed while the file was being read, so a reload
    /// never silently throws away newer input, and with `pathChanged` if the document was moved to
    /// another file meanwhile.
    public func execute(document: DocumentSession) async throws {
        let baseVersion = document.version
        let path = document.path
        let file = try await store.read(path: path, maximumBytes: maximumBytes)
        try Task.checkCancellation()
        // Save As gives the document another file without changing its version; what was read is
        // the old file's text and is not for this document any more.
        guard document.path == path else { throw DocumentError.pathChanged }
        if !file.text.hasSameContents(as: document.text) {
            try document.replaceText(file.text, expectedVersion: baseVersion)
        } else if document.version != baseVersion {
            throw DocumentError.staleVersion(expected: baseVersion, actual: document.version)
        }
        document.acknowledgeLoad(of: file)
    }
}
