import IDEDomain

public enum SaveError: Error, Equatable, Sendable {
    case saveInProgress(DocumentID)
}

public struct SaveReceipt: Equatable, Sendable {
    public let savedVersion: UInt64
    public let isCurrent: Bool
}

@MainActor
public final class SaveDocumentUseCase {
    private let store: any DocumentFileStore
    private var inFlight: Set<DocumentID> = []

    public init(store: any DocumentFileStore) {
        self.store = store
    }

    /// One instance must be shared across views of the same workspace.
    public func execute(document: DocumentSession) async throws -> SaveReceipt {
        guard inFlight.insert(document.id).inserted else {
            throw SaveError.saveInProgress(document.id)
        }
        defer { inFlight.remove(document.id) }

        try Task.checkCancellation()
        let snapshot = document.snapshot()
        try await store.write(snapshot)
        // There may have been edits during await. Acknowledge the captured version.
        // Once write succeeded, retain this fact even if the caller now cancels.
        document.acknowledgeSave(of: snapshot)
        return SaveReceipt(
            savedVersion: snapshot.version,
            isCurrent: document.version == snapshot.version
        )
    }
}
