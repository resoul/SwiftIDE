import Foundation
import IDEDomain

public struct ExternalChangePolicy: Sendable, Equatable {
    /// How long after the last event the file is looked at: editors and tools write in several steps.
    public var debounce: Duration
    /// How long to wait between two looks, so that a file still being written, or deleted and made
    /// again, is read once it has settled.
    public var settle: Duration
    public var maximumLooks: Int

    public init(debounce: Duration = .milliseconds(250), settle: Duration = .milliseconds(300), maximumLooks: Int = 5) {
        self.debounce = debounce
        self.settle = settle
        self.maximumLooks = maximumLooks
    }

    public static let standard = ExternalChangePolicy()
}

/// Watches the file of one document and says what happened to it (ADR-017).
///
/// Events only mean "look". The monitor looks at the file by its bytes, after a short wait and once
/// more to be sure, and judges it against the revision the document is based on. Its own saves,
/// a touch and a rewrite with the same bytes therefore change nothing. A clean document follows
/// the file; one with unsaved changes is never touched, and the user is told instead.
@MainActor
public final class ExternalChangeMonitor {
    public enum State: Equatable, Sendable {
        /// Nothing to say, or the user dismissed what there was.
        case none
        /// The document had no unsaved changes, so it was reloaded from the file.
        case reloaded
        /// The file changed, and so did the document: nothing was reloaded.
        case changedWhileEdited
        case removed
        /// The file changed but cannot be read as the document's text.
        case unreadable(FileStoreError)
    }

    public private(set) var state: State = .none {
        didSet { if state != oldValue { onChange?(state) } }
    }
    public var onChange: (@MainActor (State) -> Void)?

    private let session: DocumentSession
    private let files: any DocumentFileStore
    private let watcher: any FileWatching
    private let reloader: ReloadDocumentUseCase
    private let policy: ExternalChangePolicy
    private let clock: any DelayClock

    private var handle: (any FileWatchHandle)?
    private var watchedPath: String?
    private var debounce: Task<Void, Never>?
    private var evaluation: Task<Void, Never>?
    private var rerun = false
    /// The file's revision at the last look that found it changed.
    private var latest: FileRevision?
    /// A revision the user chose to keep their text against ("Keep Mine").
    private var kept: FileRevision?
    /// A situation the user dismissed: it is not announced again while it stays the same.
    private var dismissed: State?
    private var saveSubscription: UUID?
    private var isStopped = false
    /// The monitor's own reload is under way: the save notification it causes needs no new look.
    private var isReloading = false

    public init(
        session: DocumentSession,
        files: any DocumentFileStore,
        watcher: any FileWatching,
        reload: ReloadDocumentUseCase,
        policy: ExternalChangePolicy = .standard,
        clock: any DelayClock = SystemDelayClock()
    ) {
        self.session = session
        self.files = files
        self.watcher = watcher
        self.reloader = reload
        self.policy = policy
        self.clock = clock
        // A save changes what the document is based on, and Save As changes the file.
        saveSubscription = session.subscribeToSaves { [weak self] in
            guard let self else { return }

            refreshWatch()
            if !isReloading { eventArrived() }
        }
        refreshWatch()
    }

    isolated deinit {
        stop()
    }

    /// A look or a wait is under way. For tests.
    public var isBusy: Bool { debounce != nil || evaluation != nil }

    public func waitUntilIdle() async {
        while let current = evaluation { await current.value }
    }

    public func stop() {
        isStopped = true
        debounce?.cancel()
        debounce = nil
        handle?.cancel()
        handle = nil
        watchedPath = nil
        if let saveSubscription { session.unsubscribeFromSaves(saveSubscription) }
        saveSubscription = nil
    }

    // MARK: Answers to the notice

    /// "Reload": the file's text replaces the document's, as an ordinary edit that can be undone.
    public func reload() async throws {
        try await reloader.execute(document: session)
        kept = nil
        dismissed = nil
        state = .none
    }

    /// "Keep Mine": the document stays as it is. This version of the file is not asked about again;
    /// saving still reports the conflict.
    public func keepMine() {
        kept = latest
        dismissed = nil
        state = .none
    }

    /// "OK": the notice goes, and the same situation is not announced again.
    public func dismiss() {
        guard state != .none else { return }

        dismissed = state
        state = .none
    }

    // MARK: Watching

    private func refreshWatch() {
        guard !isStopped else { return }

        let wanted: String? = session.isUntitled ? nil : session.path
        guard wanted != watchedPath else { return }

        handle?.cancel()
        handle = nil
        watchedPath = wanted
        // Another file: what was known about the old one does not apply.
        kept = nil
        latest = nil
        dismissed = nil
        state = .none
        if let wanted {
            handle = watcher.watch(path: wanted) { [weak self] in
                Task { @MainActor in self?.eventArrived() }
            }
        }
    }

    private func eventArrived() {
        guard !isStopped, watchedPath != nil else { return }

        // A look is under way: it may have missed this event, so look again when it is done.
        if evaluation != nil {
            rerun = true

            return
        }

        debounce?.cancel()
        let clock = clock
        let delay = policy.debounce
        debounce = Task { [weak self] in
            try? await clock.sleep(for: delay)
            guard !Task.isCancelled else { return }

            self?.startEvaluation()
        }
    }

    private func startEvaluation() {
        debounce = nil
        evaluation = Task { [weak self] in
            await self?.evaluate()
            self?.evaluationFinished()
        }
    }

    private func evaluationFinished() {
        evaluation = nil
        if rerun {
            rerun = false
            eventArrived()
        }
    }

    // MARK: Looking

    private func matchesDocument(_ revision: FileRevision?) -> Bool {
        guard let revision, let base = session.diskRevision else { return false }

        return revision.hasSameContent(as: base)
    }

    /// The file as it is once it has stopped changing: nil if it is not there.
    private func settledRevision(of path: String) async throws -> FileRevision? {
        var previous: FileRevision??
        var current: FileRevision?
        for _ in 0..<policy.maximumLooks {
            current = try await files.currentRevision(path: path, assumingUnchangedFrom: session.diskRevision)
            if matchesDocument(current) { return current }
            if let previous, previous == current { return current }
            previous = .some(current)
            try? await clock.sleep(for: policy.settle)
            if isStopped || watchedPath != path { return current }
        }

        return current
    }

    private func evaluate() async {
        guard !isStopped, let path = watchedPath else { return }

        let observed: FileRevision?
        do {
            observed = try await settledRevision(of: path)
        } catch is CancellationError {
            return
        } catch {
            return raise(.unreadable(Self.reason(error)))
        }
        guard !isStopped, watchedPath == path else { return }

        guard let revision = observed else { return raise(.removed) }

        if matchesDocument(revision) {
            // What was wrong is over. A notice that only informs ("reloaded") stays until dismissed.
            kept = nil
            dismissed = nil
            if state != .reloaded { state = .none }

            return
        }

        latest = revision
        if let kept, kept.hasSameContent(as: revision) { return }
        if session.isDirty || session.isComposing { return raise(.changedWhileEdited) }
        await reloadClean()
    }

    private func reloadClean() async {
        let before = session.version
        isReloading = true
        defer { isReloading = false }
        do {
            try await reloader.execute(document: session)
            kept = nil
            if session.version != before {
                raise(.reloaded)
            } else if state != .reloaded {
                state = .none   // the bytes differ but the text does not (a BOM, say): nothing to tell
            }
        } catch is CancellationError {
            return
        } catch DocumentError.pathChanged {
            return   // Save As moved the document; the save notification starts a look at the new file
        } catch DocumentError.staleVersion, DocumentError.compositionInProgress {
            // Typed while the file was being read: those keystrokes are not to be overwritten.
            raise(.changedWhileEdited)
        } catch {
            raise(.unreadable(Self.reason(error)))
        }
    }

    private func raise(_ new: State) {
        if dismissed == new { return }
        dismissed = nil
        state = new
    }

    private static func reason(_ error: Error) -> FileStoreError {
        if let error = error as? FileStoreError { return error }

        return .io(code: Int32(truncatingIfNeeded: (error as NSError).code))
    }
}
