import Foundation
import IDEDomain

public enum DocumentError: Error, Equatable, Sendable {
    case staleVersion(expected: UInt64, actual: UInt64)
    case versionExhausted
    case reentrantEdit
    /// Programmatic edits (format, completion, language actions) must not touch marked text.
    case compositionInProgress
}

/// Owns revision/save metadata. Its injected backend is the only live text owner; the session
/// keeps the last *consistent* text, always paired with `version`.
@MainActor
public final class DocumentSession: NativeEditReceiver {
    public let id: DocumentID
    public let path: String
    private let backend: any DocumentEditingBackend
    private var observers: [UUID: @MainActor (DocumentChangeSet) -> Void] = [:]
    private var compositionObservers: [UUID: @MainActor (CompositionEvent) -> Void] = [:]
    private var compositionWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var committedText: String
    private var isPublishing = false
    private var isCommitting = false
    private var deferredNativeCommit: NativeEditCommit?

    /// Last consistent text; never ahead of or behind `version`.
    public var text: String { committedText }
    public private(set) var version: UInt64 = 0
    public private(set) var savedVersion: UInt64 = 0
    public private(set) var isComposing = false
    /// How many native changes arrived without an exact edit log and were rebuilt by diff.
    public private(set) var reconciliationCount = 0

    public var isDirty: Bool { version != savedVersion }

    /// Represents content already loaded from storage.
    public init(id: DocumentID = DocumentID(), path: String, backend: any DocumentEditingBackend) {
        self.id = id
        self.path = path
        self.backend = backend
        self.committedText = backend.text
        backend.attach(nativeEditReceiver: self)
    }

    public func replaceText(_ replacement: String, expectedVersion: UInt64) throws {
        try apply(
            [DocumentEdit(range: UTF16TextRange(location: 0, length: text.utf16.count), replacement: replacement)],
            expectedVersion: expectedVersion
        )
    }

    public func apply(
        _ edits: [DocumentEdit], expectedVersion: UInt64, origin: EditOrigin = .command
    ) throws {
        guard !isPublishing, !isCommitting else { throw DocumentError.reentrantEdit }
        guard !isComposing else { throw DocumentError.compositionInProgress }
        // A mutation nobody reported must not let a plan be built from outdated text.
        reconcileUnobservedMutation()
        guard expectedVersion == version else {
            throw DocumentError.staleVersion(expected: expectedVersion, actual: version)
        }
        guard let plan = try DocumentEditPlanner.prepare(edits, in: committedText) else { return }
        guard version < UInt64.max else { throw DocumentError.versionExhausted }
        let oldVersion = version
        isCommitting = true
        backend.commit(plan)
        isCommitting = false
        committedText = plan.resultText
        version += 1
        publish(DocumentChangeSet(
            documentID: id, oldVersion: oldVersion, newVersion: version,
            edits: plan.edits, origin: origin
        ))
    }

    @discardableResult
    public func subscribeToChanges(_ observer: @escaping @MainActor (DocumentChangeSet) -> Void) -> UUID {
        let id = UUID()
        observers[id] = observer
        return id
    }

    public func unsubscribeFromChanges(_ id: UUID) {
        observers.removeValue(forKey: id)
    }

    public func snapshot() -> DocumentSnapshot {
        DocumentSnapshot(documentID: id, path: path, version: version, text: committedText)
    }

    // Only application scenarios can acknowledge persistence.
    func acknowledgeSave(of snapshot: DocumentSnapshot) {
        precondition(snapshot.documentID == id && snapshot.path == path)
        precondition(snapshot.version <= version)
        savedVersion = snapshot.version
    }

    // MARK: Native edits

    public func allowsNativeEdit() -> Bool {
        !isPublishing && !isCommitting && version < UInt64.max
    }

    public func nativeEditDidCommit(_ commit: NativeEditCommit) {
        // A programmatic commit publishes itself once it returns from the backend.
        guard !isCommitting else { return }
        guard !isPublishing else {
            // Observers must not edit; if storage changed anyway, reconcile after publication
            // from the real text rather than reorder the change currently being delivered.
            deferredNativeCommit = NativeEditCommit(
                transactionID: commit.transactionID, origin: commit.origin, exactEdits: nil
            )
            return
        }
        let actual = backend.text
        // Attribute-only, no-op and repeated callbacks of an already reconciled transaction.
        guard !actual.hasSameContents(as: committedText) else { return }

        let edits: [DocumentEdit]
        var isReconciled = false
        if let exact = commit.exactEdits,
           let plan = try? DocumentEditPlanner.prepare(exact, in: committedText),
           plan.resultText.hasSameContents(as: actual) {
            edits = plan.edits
        } else if let diff = TextDiff.singleReplacement(from: committedText, to: actual) {
            edits = [diff]
            isReconciled = true
            reconciliationCount += 1
        } else {
            return
        }
        guard version < UInt64.max else {
            committedText = actual
            return
        }
        let oldVersion = version
        committedText = actual
        version += 1
        publish(DocumentChangeSet(
            documentID: id, oldVersion: oldVersion, newVersion: version, edits: edits,
            origin: commit.origin, transactionID: commit.transactionID, isReconciled: isReconciled
        ))
    }

    private func reconcileUnobservedMutation() {
        guard !backend.text.hasSameContents(as: committedText) else { return }
        nativeEditDidCommit(NativeEditCommit(origin: .typing, exactEdits: nil))
    }

    private func publish(_ change: DocumentChangeSet) {
        // Broadcast one committed transaction to every active subscriber.
        // Observers enqueue background work; nested text edits must wait until publication ends.
        isPublishing = true
        for observer in Array(observers.values) { observer(change) }
        isPublishing = false
        if let pending = deferredNativeCommit {
            deferredNativeCommit = nil
            nativeEditDidCommit(pending)
        }
    }

    // MARK: Composition

    public func compositionDidChange(_ event: CompositionEvent) {
        isComposing = event != .ended
        for observer in Array(compositionObservers.values) { observer(event) }
        if event == .ended { resumeCompositionWaiters() }
    }

    @discardableResult
    public func subscribeToComposition(_ observer: @escaping @MainActor (CompositionEvent) -> Void) -> UUID {
        let id = UUID()
        compositionObservers[id] = observer
        return id
    }

    public func unsubscribeFromComposition(_ id: UUID) {
        compositionObservers.removeValue(forKey: id)
    }

    /// Asks the editor to finish marked text the standard way. May complete later.
    public func requestCompositionEnd() {
        guard isComposing else { return }
        backend.endComposition()
    }

    /// Returns once no composition is active. Callers must read state synchronously afterwards,
    /// without suspending, because a new composition can begin between resume and use.
    public func waitForCompositionEnd() async throws {
        while isComposing {
            try Task.checkCancellation()
            let waiterID = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    if Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        compositionWaiters[waiterID] = continuation
                    }
                }
            } onCancel: {
                Task { @MainActor in self.cancelCompositionWaiter(waiterID) }
            }
        }
    }

    private func resumeCompositionWaiters() {
        let waiters = compositionWaiters
        compositionWaiters.removeAll()
        for continuation in waiters.values { continuation.resume() }
    }

    private func cancelCompositionWaiter(_ id: UUID) {
        compositionWaiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
}
