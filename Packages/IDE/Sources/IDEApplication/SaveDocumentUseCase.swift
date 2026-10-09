import Foundation
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

/// One save of one document, from the first request until the write finished.
@MainActor
private final class SaveOperation {
    var trigger: SaveTrigger
    /// Until the snapshot is captured the operation can still absorb other requests.
    var isWaitingForComposition = true
    private var joiners: [UUID: CheckedContinuation<Result<SaveReceipt, Error>, Never>] = [:]

    init(trigger: SaveTrigger) {
        self.trigger = trigger
    }

    func join() async -> Result<SaveReceipt, Error> {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: .failure(CancellationError()))
                } else {
                    joiners[id] = continuation
                }
            }
        } onCancel: {
            Task { @MainActor in self.cancelJoiner(id) }
        }
    }

    func finish(_ result: Result<SaveReceipt, Error>) {
        let waiting = joiners
        joiners.removeAll()
        for continuation in waiting.values { continuation.resume(returning: result) }
    }

    private func cancelJoiner(_ id: UUID) {
        joiners.removeValue(forKey: id)?.resume(returning: .failure(CancellationError()))
    }
}

@MainActor
public final class SaveDocumentUseCase {
    private let store: any DocumentFileStore
    private var operations: [DocumentID: SaveOperation] = [:]

    public init(store: any DocumentFileStore) {
        self.store = store
    }

    /// One instance must be shared across views of the same workspace.
    ///
    /// A file changed on disk since it was read or last saved makes the save fail with
    /// `FileStoreError.conflict` and nothing is written. Replacing it anyway needs the explicit
    /// `overwritingExternalChanges`, which the user chooses after seeing the conflict.
    public func execute(
        document: DocumentSession, trigger: SaveTrigger = .explicit,
        overwritingExternalChanges: Bool = false
    ) async throws -> SaveReceipt {
        // A save still waiting for composition has captured nothing yet, so a new request joins
        // it instead of failing, and an explicit one promotes a waiting autosave.
        while let running = operations[document.id] {
            guard running.isWaitingForComposition else {
                throw SaveError.saveInProgress(document.id)
            }
            if trigger == .explicit, running.trigger == .autosave {
                running.trigger = .explicit
                document.requestCompositionEnd()
            }
            switch await running.join() {
            case .success(let receipt):
                return receipt
            case .failure(let error):
                // The save we joined was cancelled; that is not our cancellation. Start over.
                if error is CancellationError, !Task.isCancelled { continue }
                throw error
            }
        }

        let operation = SaveOperation(trigger: trigger)
        operations[document.id] = operation
        do {
            let receipt = try await run(
                operation, document: document, overwriting: overwritingExternalChanges
            )
            operations.removeValue(forKey: document.id)
            operation.finish(.success(receipt))
            return receipt
        } catch {
            operations.removeValue(forKey: document.id)
            operation.finish(.failure(error))
            throw error
        }
    }

    private func run(
        _ operation: SaveOperation, document: DocumentSession, overwriting: Bool
    ) async throws -> SaveReceipt {
        // Never persist a pre-composition snapshot while marked text is live. The wait is not
        // followed by a suspension before the capture, so the snapshot is the final text.
        if operation.trigger == .explicit { document.requestCompositionEnd() }
        try await document.waitForCompositionEnd()
        try Task.checkCancellation()
        operation.isWaitingForComposition = false
        let snapshot = document.snapshot()
        // The disk revision is captured together with the snapshot: the write is judged against
        // the file this text was based on, whatever happens to the document meanwhile.
        let expectation: SaveExpectation = overwriting ? .overwrite : .revision(document.diskRevision)
        let revision = try await store.write(snapshot, expecting: expectation)
        // There may have been edits during await. Acknowledge the captured version.
        // Once write succeeded, retain this fact even if the caller now cancels.
        document.acknowledgeSave(of: snapshot, revision: revision)
        return SaveReceipt(
            savedVersion: snapshot.version,
            isCurrent: document.version == snapshot.version
        )
    }
}
