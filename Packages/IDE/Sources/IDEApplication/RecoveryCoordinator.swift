import Foundation
import IDEDomain

extension DocumentSession {
    /// Where this document's unsaved text is kept: under its file's path, or, for a document that
    /// never had a file, under its own id.
    public var recoveryKey: RecoveryKey {
        isUntitled ? .scratch(id) : .file(atPath: path)
    }
}

/// Keeps the unsaved text of one document where a crash cannot take it (ADR-016).
///
/// A document with unsaved changes is written to the recovery store a little after the last edit
/// (and never later than `maximumDelay` after the first one, however steadily the user types);
/// when it becomes clean again, by a save or a save under another name, its record is removed.
/// The text is copied on the main thread, which is why a document over the size limit is not kept
/// at all, and what is written goes out through one queue, so a slow write can never land after
/// the removal that follows it.
/// What `RecoveryCoordinator.flush()` found in the store.
public enum Safekeeping: Equatable, Sendable {
    /// The document has no unsaved changes: there is nothing to keep.
    case nothingUnsaved
    /// The store holds the document's text as of this version, under this key.
    case written(RecoveryKey, version: UInt64)
}

@MainActor
public final class RecoveryCoordinator {
    public enum Status: Equatable, Sendable {
        case protecting
        /// The document is over the size limit: its unsaved text is not kept.
        case tooLarge
        /// The last write failed; the next edit tries again.
        case failing(String)
    }

    public private(set) var status: Status = .protecting {
        didSet { if status != oldValue { onStatusChange?(status) } }
    }
    public var onStatusChange: (@MainActor (Status) -> Void)?

    private let session: DocumentSession
    private let store: any RecoveryStore
    private let policy: RecoveryPolicy
    private let clock: any DelayClock
    private var timer: Task<Void, Never>?
    /// When the oldest unsaved edit that is not yet in a write happened.
    private var firstPending: Duration?
    /// Keys that hold, or are about to hold, a record of this document.
    private var kept: Set<RecoveryKey> = []
    /// The version of the latest write that was queued, to not write one version twice.
    private var queuedVersion: UInt64?
    private var tail: Task<Void, Never> = Task {}
    private var changeSubscription: UUID?
    private var saveSubscription: UUID?
    private var isStopped = false
    /// Set while the user has agreed to lose the unsaved text (a quit that may still be refused):
    /// nothing is written, and the record is gone.
    private var isWithdrawn = false
    /// The latest record known to be in the store: its key and the document version it holds.
    private var written: (key: RecoveryKey, version: UInt64)?

    public init(
        session: DocumentSession, store: any RecoveryStore, policy: RecoveryPolicy = .standard,
        clock: any DelayClock = SystemDelayClock()
    ) {
        self.session = session
        self.store = store
        self.policy = policy
        self.clock = clock
        changeSubscription = session.subscribeToChanges { [weak self] _ in self?.stateDidChange() }
        saveSubscription = session.subscribeToSaves { [weak self] in self?.stateDidChange() }
        if session.isDirty { stateDidChange() }
    }

    isolated deinit {
        stopObserving()
    }

    // MARK: Following the document

    private func stateDidChange() {
        guard !isStopped else { return }
        if session.isDirty {
            if !isWithdrawn { scheduleWrite() }
        } else {
            becameClean()
        }
    }

    private func scheduleWrite() {
        let now = clock.now
        let began = firstPending ?? now
        firstPending = began
        let remaining = max(.zero, policy.maximumDelay - (now - began))
        let delay = min(policy.debounce, remaining)
        timer?.cancel()
        let clock = clock
        timer = Task { [weak self] in
            try? await clock.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.timerFired()
        }
    }

    private func timerFired() {
        timer = nil
        guard !isStopped, !isWithdrawn, session.isDirty else { return }
        // Marked text is not part of the document until the input method commits it.
        if session.isComposing {
            firstPending = nil
            scheduleWrite()
            return
        }
        firstPending = nil
        queueWrite()
    }

    private func becameClean() {
        timer?.cancel()
        timer = nil
        firstPending = nil
        queuedVersion = nil
        if status == .tooLarge { status = .protecting }
        removeKept()
    }

    // MARK: Writing and removing

    @discardableResult
    private func queueWrite() -> Bool {
        guard session.isDirty else { return false }
        guard session.utf16Length <= policy.maximumUTF16Length else {
            queuedVersion = nil
            status = .tooLarge
            removeKept()
            return false
        }
        if status == .tooLarge { status = .protecting }
        guard queuedVersion != session.version else { return false }

        let key = session.recoveryKey
        let path: String? = session.isUntitled ? nil : session.path
        let title = session.isUntitled ? "Untitled" : (session.path as NSString).lastPathComponent
        // A Save As gave the document another name: what was kept under the old one is stale.
        let stale = kept.subtracting([key])
        kept.insert(key)
        let version = session.version
        queuedVersion = version
        let store = store
        let session = session
        enqueue { [weak self] in
            do {
                // Copied slice by slice, so that a large document does not stop the window; the
                // copy is of the document as it is when the turn comes, which may be newer.
                guard session.isDirty else { return }
                let capture = try await session.capture()
                guard session.isDirty else { return }   // saved while it was being copied
                let capturedVersion = capture.snapshot.version
                let record = RecoveryRecord(
                    key: key, path: path, title: title, text: capture.snapshot.text,
                    encoding: capture.snapshot.encoding, baseRevision: capture.diskRevision, savedAt: Date()
                )
                try await store.write(record)
                for old in stale { try? await store.remove(old) }
                self?.writeSucceeded(key, version: capturedVersion)
            } catch is CancellationError {
                return
            } catch {
                self?.writeFailed(version, error)
            }
        }
        return true
    }

    private func writeSucceeded(_ key: RecoveryKey, version: UInt64) {
        if kept.contains(key) { written = (key, version) }
        if case .failing = status { status = .protecting }
    }

    private func writeFailed(_ version: UInt64, _ error: Error) {
        if queuedVersion == version { queuedVersion = nil }
        status = .failing(String(describing: error))
    }

    private func removeKept() {
        guard !kept.isEmpty else { return }
        let keys = kept
        kept.removeAll()
        written = nil
        let store = store
        enqueue { [weak self] in
            for key in keys { try? await store.remove(key) }
            self?.written = nil   // a write that landed just before the removal is gone too
        }
    }

    /// Store operations run one after another, in the order they were asked for.
    private func enqueue(_ operation: @escaping @MainActor () async -> Void) {
        let previous = tail
        tail = Task { @MainActor in
            await previous.value
            await operation()
        }
    }

    // MARK: Asking for it

    /// Writes the unsaved text now, if there is any that is not yet written, and returns once it
    /// is in the store. For the moments the user may be about to lose the app: it goes to the
    /// background, or quits.
    ///
    /// Returns what is in the store afterwards: nothing is unsaved, or a record of the document at
    /// a stated version. That version is the one the write captured; the document may have been
    /// edited since (typing goes on while the store works), so it is a guarantee about that text
    /// and no more. Nil if the text is not kept: the write failed or the document is too large.
    /// A caller about to let go of another copy of the same text asks that the version be at least
    /// the one it holds.
    @discardableResult
    public func flush() async -> Safekeeping? {
        guard !isStopped else { return nil }
        if isWithdrawn { return session.isDirty ? nil : .nothingUnsaved }
        timer?.cancel()
        timer = nil
        firstPending = nil
        queueWrite()
        await waitUntilIdle()
        guard session.isDirty else { return .nothingUnsaved }
        guard status == .protecting, let written else { return nil }
        return .written(written.key, version: written.version)
    }

    /// The user agreed to lose these changes in a quit that is not final yet: the record goes and
    /// nothing is written until `resume()`. Unlike `discard()` it can be undone, because the quit
    /// can still be refused (something was typed, a window appeared).
    public func withdraw() async {
        isWithdrawn = true
        timer?.cancel()
        timer = nil
        firstPending = nil
        queuedVersion = nil
        removeKept()
        await waitUntilIdle()
    }

    /// The quit did not happen: the unsaved text is protected again.
    public func resume() {
        guard isWithdrawn else { return }
        isWithdrawn = false
        stateDidChange()
    }

    /// The user chose to drop these changes (closed without saving, or quit and discarded): the
    /// record goes, and nothing is written for this document any more.
    public func discard() async {
        isStopped = true
        timer?.cancel()
        timer = nil
        stopObserving()
        removeKept()
        await waitUntilIdle()
    }

    /// Returns when every write and removal asked for so far has been done.
    public func waitUntilIdle() async {
        while true {
            let current = tail
            await current.value
            if current == tail { return }
        }
    }

    private func stopObserving() {
        timer?.cancel()
        if let changeSubscription { session.unsubscribeFromChanges(changeSubscription) }
        if let saveSubscription { session.unsubscribeFromSaves(saveSubscription) }
        changeSubscription = nil
        saveSubscription = nil
    }
}
