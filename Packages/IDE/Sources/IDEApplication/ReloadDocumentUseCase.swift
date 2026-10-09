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
    /// never silently throws away newer input.
    public func execute(document: DocumentSession) async throws {
        let baseVersion = document.version
        let file = try await store.read(path: document.path, maximumBytes: maximumBytes)
        try Task.checkCancellation()
        if !file.text.hasSameContents(as: document.text) {
            try document.replaceText(file.text, expectedVersion: baseVersion)
        } else if document.version != baseVersion {
            throw DocumentError.staleVersion(expected: baseVersion, actual: document.version)
        }
        document.acknowledgeLoad(of: file)
    }
}
