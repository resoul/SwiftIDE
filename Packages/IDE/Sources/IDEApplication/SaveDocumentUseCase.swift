import IDEDomain

public enum SaveError: Error, Equatable, Sendable {
    case saveInProgress(DocumentID)
}

public struct SaveReceipt: Equatable, Sendable {
    public let savedVersion: UInt64
    public let isCurrent: Bool
}

public enum SaveTrigger: Sendable {
    /// User asked to save: marked text is finished first.
    case explicit
    /// Background save: waits for composition to end and never interrupts input.
    case autosave
}

@MainActor
public final class SaveDocumentUseCase {
    private let store: any DocumentFileStore
    private var inFlight: Set<DocumentID> = []

    public init(store: any DocumentFileStore) {
        self.store = store
    }

    /// One instance must be shared across views of the same workspace.
    public func execute(
        document: DocumentSession, trigger: SaveTrigger = .explicit
    ) async throws -> SaveReceipt {
        guard inFlight.insert(document.id).inserted else {
            throw SaveError.saveInProgress(document.id)
        }
        defer { inFlight.remove(document.id) }

        // Never persist a pre-composition snapshot while marked text is live. The wait is not
        // followed by a suspension before the capture, so the snapshot is the final text.
        if trigger == .explicit { document.requestCompositionEnd() }
        try await document.waitForCompositionEnd()
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
