import Foundation
import IDEDomain

public enum DocumentError: Error, Equatable, Sendable {
    case staleVersion(expected: UInt64, actual: UInt64)
    case versionExhausted
    case reentrantEdit
    /// Programmatic edits (format, completion, language actions) must not touch marked text.
    case compositionInProgress
    /// The document was saved under another name while something was being done for its old file.
    case pathChanged
}

/// Owns revision/save metadata. Its injected backend is the only text owner: the session keeps no
/// copy, only the version, the length, and the backend's edit generation it last accounted for.
/// Everything it does per edit is proportional to the edit, never to the document.
@MainActor
public final class DocumentSession: NativeEditReceiver {
    public let id: DocumentID
    /// The file this document is saved to. A scratch document has a placeholder until Save As.
    public private(set) var path: String
    /// True until the document is first saved under a name. It has no file to compare against.
    public private(set) var isUntitled: Bool
    private let backend: any DocumentEditingBackend
    /// In the order they subscribed: an observer that must act before another one (stop colouring
    /// before the highlighter is handed a huge edit) subscribes first.
    private var observers: [(id: UUID, call: @MainActor (DocumentChangeSet) -> Void)] = []
    private var compositionObservers: [UUID: @MainActor (CompositionEvent) -> Void] = [:]
    private var saveObservers: [UUID: @MainActor () -> Void] = [:]
    private var compositionWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var isPublishing = false
    private var isCommitting = false
    private var deferredNativeCommits: [NativeEditCommit] = []
    /// UTF-16 length of the text at `version`.
    private var length: Int
    /// The backend's `editGeneration` after the last edit this session accounted for.
    private var knownGeneration: UInt64

    /// The backend's current text: a full copy, O(n). Use `snapshot()` for text paired with a
    /// version, and never read this per keystroke.
    public var text: String { backend.text }
    public private(set) var version: UInt64 = 0
    public private(set) var savedVersion: UInt64 = 0
    public private(set) var isComposing = false
    /// What the file looked like when it was last read or written; the base of the next save.
    public private(set) var diskRevision: FileRevision?
    public private(set) var encoding: FileEncoding
    /// How many native changes arrived without an exact edit log and were rebuilt by diff.
    public private(set) var reconciliationCount = 0

    public var isDirty: Bool { version != savedVersion }

    /// UTF-16 length of the text at `version`; O(1).
    public var utf16Length: Int { length }

    /// Represents content already loaded from storage.
    public init(
        id: DocumentID = DocumentID(),
        path: String,
        backend: any DocumentEditingBackend,
        diskRevision: FileRevision? = nil,
        encoding: FileEncoding = .utf8,
        isUntitled: Bool = false
    ) {
        self.id = id
        self.path = path
        self.isUntitled = isUntitled
        self.backend = backend
        self.diskRevision = diskRevision
        self.encoding = encoding
        self.length = backend.utf16Length
        self.knownGeneration = backend.editGeneration
        backend.attach(nativeEditReceiver: self)
    }

    /// A document whose text, encoding and disk revision come from a file just read.
    public convenience init(id: DocumentID = DocumentID(), loaded: LoadedFile, backend: any DocumentEditingBackend) {
        self.init(
            id: id,
            path: loaded.path,
            backend: backend,
            diskRevision: loaded.revision,
            encoding: loaded.encoding
        )
    }

    public func replaceText(_ replacement: String, expectedVersion: UInt64) throws {
        try apply(
            [DocumentEdit(range: UTF16TextRange(location: 0, length: length), replacement: replacement)],
            expectedVersion: expectedVersion
        )
    }

    public func apply(
        _ edits: [DocumentEdit],
        expectedVersion: UInt64,
        origin: EditOrigin = .command
    ) throws {
        guard !isPublishing, !isCommitting else { throw DocumentError.reentrantEdit }

        guard !isComposing else { throw DocumentError.compositionInProgress }

        // A mutation nobody reported must not let a plan be built from outdated text.
        reconcileUnobservedMutation()
        guard expectedVersion == version else {
            throw DocumentError.staleVersion(expected: expectedVersion, actual: version)
        }

        guard let plan = try DocumentEditPlanner.prepare(edits, in: backend) else { return }

        guard version < UInt64.max else { throw DocumentError.versionExhausted }

        let oldVersion = version
        isCommitting = true
        backend.commit(plan)
        isCommitting = false
        length = backend.utf16Length
        knownGeneration = backend.editGeneration
        version += 1
        publish(DocumentChangeSet(
            documentID: id,
            oldVersion: oldVersion,
            newVersion: version,
            edits: plan.edits,
            origin: origin
        ))
    }

    @discardableResult
    public func subscribeToChanges(_ observer: @escaping @MainActor (DocumentChangeSet) -> Void) -> UUID {
        let id = UUID()
        observers.append((id, observer))

        return id
    }

    public func unsubscribeFromChanges(_ id: UUID) {
        observers.removeAll { $0.id == id }
    }

    /// Called after the saved state changed without the text changing: a save, a save under a new
    /// name, a reload. Whether the document is clean now is `isDirty`.
    @discardableResult
    public func subscribeToSaves(_ observer: @escaping @MainActor () -> Void) -> UUID {
        let id = UUID()
        saveObservers[id] = observer

        return id
    }

    public func unsubscribeFromSaves(_ id: UUID) {
        saveObservers.removeValue(forKey: id)
    }

    private func notifySaved() {
        for observer in Array(saveObservers.values) { observer() }
    }

    /// The text at the current version. The one place that copies the whole document.
    public func snapshot() -> DocumentSnapshot {
        snapshot(forPath: path)
    }

    /// The same, addressed to another file: what Save As writes.
    func snapshot(forPath target: String) -> DocumentSnapshot {
        reconcileUnobservedMutation()

        return DocumentSnapshot(documentID: id, path: target, version: version, text: backend.text, encoding: encoding)
    }

    // Only application scenarios can acknowledge persistence.
    func acknowledgeSave(of snapshot: DocumentSnapshot, revision: FileRevision) {
        precondition(snapshot.documentID == id && snapshot.path == path)
        precondition(snapshot.version <= version)
        savedVersion = snapshot.version
        diskRevision = revision
        notifySaved()
    }

    /// The snapshot was written under a new name: the document now lives there.
    func acknowledgeSaveAs(of snapshot: DocumentSnapshot, revision: FileRevision) {
        precondition(snapshot.documentID == id)
        precondition(snapshot.version <= version)
        path = snapshot.path
        isUntitled = false
        savedVersion = snapshot.version
        diskRevision = revision
        notifySaved()
    }

    /// Declares that the current text was written against `revision` of the file, not against the
    /// file as it was read: recovered text is based on the file as it was when the app last kept
    /// it, and a save is judged against that, so changes made since then are a conflict.
    func rebaseOnto(_ revision: FileRevision?) {
        diskRevision = revision
    }

    /// The current text now matches this file: nothing is unsaved.
    func acknowledgeLoad(of file: LoadedFile) {
        precondition(file.path == path)
        savedVersion = version
        diskRevision = file.revision
        encoding = file.encoding
        notifySaved()
    }

    // MARK: Native edits

    public func allowsNativeEdit() -> Bool {
        !isPublishing && !isCommitting && version < UInt64.max
    }

    public func nativeEditDidCommit(_ commit: NativeEditCommit) {
        // A programmatic commit publishes itself once it returns from the backend.
        guard !isCommitting else { return }

        guard !isPublishing else {
            // Observers must not edit; if storage changed anyway, account for it after the
            // publication in progress, in order, instead of reordering the change being delivered.
            deferredNativeCommits.append(commit)

            return
        }

        // A commit that covers only passes already accounted for is a repeated delivery.
        guard commit.generation > knownGeneration else { return }

        // Passes the session did not hear about mean someone edited behind its back: the
        // commit's coordinates are then relative to text the session never saw.
        let heardAbout = commit.generation >= UInt64(commit.passes)
            && commit.generation - UInt64(commit.passes) == knownGeneration
        guard heardAbout else {
            knownGeneration = commit.generation
            publishWholeDocumentReplacement(origin: commit.origin, transactionID: commit.transactionID)

            return
        }

        let edit: DocumentEdit
        var isReconciled = false
        switch commit.effect {
        case .unchanged:
            knownGeneration = commit.generation

            return
        case .replaced(let range, let replacement, let isExact):
            let expected = length - range.length + replacement.utf16.count
            guard range.location >= 0, range.length >= 0, range.location + range.length <= length,
                  backend.utf16Length == expected else {
                // The commit does not describe what is in the backend.
                knownGeneration = commit.generation
                publishWholeDocumentReplacement(origin: commit.origin, transactionID: commit.transactionID)

                return
            }

            edit = DocumentEdit(range: range, replacement: replacement)
            isReconciled = !isExact
            if isReconciled { reconciliationCount += 1 }
        case .unknown:
            knownGeneration = commit.generation
            publishWholeDocumentReplacement(origin: commit.origin, transactionID: commit.transactionID)

            return
        }
        guard version < UInt64.max else {
            length = backend.utf16Length
            knownGeneration = commit.generation

            return
        }

        let oldVersion = version
        length = backend.utf16Length
        knownGeneration = commit.generation
        version += 1
        publish(DocumentChangeSet(
            documentID: id,
            oldVersion: oldVersion,
            newVersion: version,
            edits: [edit],
            origin: commit.origin,
            transactionID: commit.transactionID,
            isReconciled: isReconciled
        ))
    }

    /// The backend changed without a trustworthy description. Everything is said to have been
    /// replaced; consumers resync from a snapshot. O(n), but only in this abnormal case.
    private func publishWholeDocumentReplacement(origin: EditOrigin, transactionID: TransactionID) {
        let oldLength = length
        let replacement = backend.text
        length = backend.utf16Length
        knownGeneration = backend.editGeneration
        reconciliationCount += 1
        guard version < UInt64.max else { return }

        let oldVersion = version
        version += 1
        publish(DocumentChangeSet(
            documentID: id,
            oldVersion: oldVersion,
            newVersion: version,
            edits: [DocumentEdit(range: UTF16TextRange(location: 0, length: oldLength), replacement: replacement)],
            origin: origin,
            transactionID: transactionID,
            isReconciled: true
        ))
    }

    var backendLength: Int { backend.utf16Length }

    func copyUnits(from start: Int, to end: Int, into copier: TextCopier) {
        backend.enumerateUTF16(in: UTF16TextRange(location: start, length: end - start)) { copier.append($0) }
    }

    func reconcileUnobservedMutation() {
        guard backend.editGeneration != knownGeneration else { return }

        publishWholeDocumentReplacement(origin: .typing, transactionID: TransactionID())
    }

    private func publish(_ change: DocumentChangeSet) {
        // Broadcast one committed transaction to every active subscriber.
        // Observers enqueue background work; nested text edits must wait until publication ends.
        isPublishing = true
        for subscribed in observers {
            // One that an earlier observer just unsubscribed must not be called any more.
            guard observers.contains(where: { $0.id == subscribed.id }) else { continue }

            subscribed.call(change)
        }
        isPublishing = false
        if !deferredNativeCommits.isEmpty {
            let pending = deferredNativeCommits
            deferredNativeCommits.removeAll()
            for commit in pending { nativeEditDidCommit(commit) }
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
