import Foundation
import IDEDomain

public enum SaveError: Error, Equatable, Sendable {
    case saveInProgress(DocumentID)
    /// A document that was never saved has no file to save to: it needs Save As.
    case untitled(DocumentID)
    /// Another open document already edits that file; two writable copies would overwrite each other.
    case targetOpenElsewhere(path: String)
    /// Another Save As is already going to that name.
    case targetBeingSaved(path: String)
}

/// What the user agreed to when choosing the name in Save As.
public enum SaveAsTarget: Equatable, Sendable {
    /// The name was free. A file that appears before the write is a conflict, not a replacement.
    case newFile
    /// The user agreed to replace *this* file, as it was when they agreed. If it has changed
    /// since (or is gone), nothing is written.
    case replacing(FileRevision)
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
    private let capturePolicy: CapturePolicy
    private var operations: [DocumentID: SaveOperation] = [:]

    public init(store: any DocumentFileStore, capturePolicy: CapturePolicy = .standard) {
        self.store = store
        self.capturePolicy = capturePolicy
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

        guard !document.isUntitled else { throw SaveError.untitled(document.id) }
        return try await perform(document, trigger: trigger, destination: .current(overwriting: overwritingExternalChanges))
    }

    /// Saves the document under a new name and moves it there: later saves go to the new file.
    ///
    /// `target` is what the user agreed to: a free name, or replacing the file as it was when
    /// they agreed. Anything else found at the name is a conflict and nothing is written. Saving
    /// under the document's own name is an ordinary save. The original file, if any, is left as
    /// it is.
    ///
    /// The name is reserved in `registry` from the start to the end, including any wait for a
    /// composition to finish, so that opening that file, or saving another document under that
    /// name, is refused meanwhile (`OpenDocumentError.beingSavedElsewhere`,
    /// `SaveError.targetBeingSaved`). Refused too while this document is already being saved.
    public func saveAs(
        document: DocumentSession, to path: String, target: SaveAsTarget, registry: DocumentRegistry
    ) async throws -> SaveReceipt {
        guard operations[document.id] == nil else { throw SaveError.saveInProgress(document.id) }
        let name = DocumentPath.canonical(path)
        if !document.isUntitled, name == document.path {
            return try await perform(document, trigger: .explicit, destination: .current(overwriting: false))
        }
        switch registry.reserve(path: name, for: document) {
        case .granted: break
        case .openElsewhere: throw SaveError.targetOpenElsewhere(path: name)
        case .reserved: throw SaveError.targetBeingSaved(path: name)
        }
        defer { registry.releaseReservation(path: name, for: document) }
        return try await perform(
            document, trigger: .explicit, destination: .newName(path: name, target: target, registry: registry)
        )
    }

    private enum Destination {
        case current(overwriting: Bool)
        case newName(path: String, target: SaveAsTarget, registry: DocumentRegistry)
    }

    private func perform(
        _ document: DocumentSession, trigger: SaveTrigger, destination: Destination
    ) async throws -> SaveReceipt {
        let operation = SaveOperation(trigger: trigger)
        operations[document.id] = operation
        do {
            let receipt = try await run(operation, document: document, destination: destination)
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
        _ operation: SaveOperation, document: DocumentSession, destination: Destination
    ) async throws -> SaveReceipt {
        // Never persist a pre-composition snapshot while marked text is live. The wait is not
        // followed by a suspension before the capture, so the snapshot is the final text.
        if operation.trigger == .explicit { document.requestCompositionEnd() }
        try await document.waitForCompositionEnd()
        try Task.checkCancellation()
        operation.isWaitingForComposition = false
        // The copy of a large document is spread over many turns of the main thread, and what is
        // typed meanwhile is part of it; the capture is of the instant it was complete.
        let explicit = operation.trigger == .explicit
        let snapshot: DocumentSnapshot
        let expectation: SaveExpectation
        switch destination {
        case .current(let overwriting):
            let capture = try await document.capture(policy: capturePolicy, endsComposition: explicit)
            snapshot = capture.snapshot
            // The disk revision is captured together with the snapshot: the write is judged
            // against the file this text was based on, whatever happens to the document meanwhile.
            expectation = overwriting ? .overwrite : .revision(capture.diskRevision)
        case .newName(let path, let target, _):
            snapshot = try await document.capture(forPath: path, policy: capturePolicy, endsComposition: explicit).snapshot
            switch target {
            case .newFile: expectation = .revision(nil)
            case .replacing(let confirmed): expectation = .revision(confirmed)
            }
        }
        let revision = try await store.write(snapshot, expecting: expectation)
        // There may have been edits during await. Acknowledge the captured version.
        // Once write succeeded, retain this fact even if the caller now cancels.
        switch destination {
        case .current:
            document.acknowledgeSave(of: snapshot, revision: revision)
        case .newName(_, _, let registry):
            document.acknowledgeSaveAs(of: snapshot, revision: revision)
            registry.register(document)
        }
        return SaveReceipt(
            savedVersion: snapshot.version,
            isCurrent: document.version == snapshot.version
        )
    }
}
