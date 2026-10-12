import Foundation

public enum GitLoadState: Equatable, Sendable {
    case idle, loading, ready
    case unavailable(String), failed(String)
    public var explanation: String {
        switch self {
        case .idle: "Git inspection"
        case .loading: "Refreshing Git…"
        case .ready: "Ready"
        case .unavailable(let reason), .failed(let reason): reason
        }
    }
}

/// One opened project's inspection lifecycle, with independent bounded requests and stale rejection.
@MainActor
public final class GitWorkspace {
    public let root: String
    public private(set) var state = GitLoadState.idle
    public private(set) var snapshot: GitSnapshot?
    public private(set) var history: [GitCommit] = []
    public private(set) var historyState = GitLoadState.idle
    public private(set) var historyTitle = "HEAD"
    public private(set) var hasMoreHistory = false
    public private(set) var selectedCommit: GitCommit?
    public private(set) var commitFiles: [GitCommitFile] = []
    public private(set) var filesState = GitLoadState.idle
    public private(set) var comparison: GitComparison?
    public private(set) var diffText = "Select a changed file to inspect its disk/index diff."
    public private(set) var diffState = GitLoadState.idle
    public var onInspect: (() -> Void)?
    public var liveUpdatesAvailable: Bool? {
        didSet { if oldValue != liveUpdatesAvailable { changed() } }
    }
    public private(set) var operationState = GitOperationState.idle
    public private(set) var operationTitle = ""
    public private(set) var operationOutput = ""
    public var prepareCheckout: ((GitRepository) async -> Bool)?
    public var checkoutFinished: ((GitRepository) -> Void)?
    public var conflictReader: (any GitConflictReading)? { service as? any GitConflictReading }
    public var trackingPlanner: (any GitTrackingPlanning)? { service as? any GitTrackingPlanning }
    public var stashReader: (any GitStashReading)? { service as? any GitStashReading }
    public var pullPlanner: (any GitPullPlanning)? { service as? any GitPullPlanning }
    public var pushPlanner: (any GitPushPlanning)? { service as? any GitPushPlanning }
    public var supportsLocalActions: Bool { mutations != nil }
    public private(set) var lastFetch: (remote: String, date: Date)?
    public var canMutate: Bool { supportsLocalActions && state == .ready && !operationState.isBusy && !stopped }
    private let mutations: (any GitMutating)?
    private var operationTask: Task<Void, Never>?
    private var operationID = UUID()
    private let service: any GitInspecting
    private var revision: String?
    private var customHistory = false
    private var epoch = UUID()
    private var diffID = UUID(), commitID = UUID()
    private var refreshTask: Task<Void, Never>?, historyTask: Task<Void, Never>?
    private var diffTask: Task<Void, Never>?, filesTask: Task<Void, Never>?
    private var observers: [UUID: () -> Void] = [:]
    private var stopped = false
    private var scheduledRefresh: Task<Void, Never>?

    public init(root: String, service: any GitInspecting, mutations: (any GitMutating)? = nil) {
        self.root = root
        self.service = service
        self.mutations = mutations ?? (service as? any GitMutating)
    }

    public func refresh() {
        guard !stopped, !operationState.isBusy else { return }

        refreshTask?.cancel()
        historyTask?.cancel()
        diffTask?.cancel()
        filesTask?.cancel()
        epoch = UUID()
        diffID = UUID()
        commitID = UUID()
        let token = epoch
        state = .loading
        if historyState == .loading { historyState = .idle }
        if filesState == .loading { filesState = .idle }
        if comparison != nil { diffState = .loading }
        changed()
        refreshTask = Task { [weak self, service, root] in
            do {
                let value = try await service.snapshot(at: root)
                guard let self, !Task.isCancelled, epoch == token, !stopped else { return }

                let differentRepository = snapshot != nil && snapshot?.repository != value.repository
                let newHead = snapshot?.head != value.head || snapshot?.repository != value.repository
                snapshot = value
                state = .ready
                refreshTask = nil
                if newHead || revision == nil {
                    customHistory = false
                    revision = value.head
                    historyTitle = value.headDescription
                    resetHistory()
                }

                if !customHistory { historyTitle = value.headDescription }
                if differentRepository {
                    comparison = nil
                    diffState = .idle
                    diffText = "Repository changed; select a new comparison."
                }

                if case .untracked(let change) = comparison,
                   !value.changes.contains(where: { $0.path == change.path && $0.decoration.isUntracked }) {
                    comparison = nil
                    diffState = .idle
                    diffText = "This file is no longer untracked; select its current change."
                }

                changed()
                if history.isEmpty, revision != nil { loadMoreHistory() }
                if let selectedCommit, filesState != .ready { select(selectedCommit) }
                if let comparison { requestDiff(comparison, openTab: false) }
            } catch {
                guard let self, !Task.isCancelled, epoch == token, !stopped else { return }

                state = Self.failure(error)
                if comparison != nil { diffState = state }
                refreshTask = nil
                changed()
            }
        }
    }

    public func scheduleRefresh() {
        guard !stopped else { return }

        scheduledRefresh?.cancel()
        scheduledRefresh = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            guard !Task.isCancelled else { return }

            self?.refresh()
        }
    }

    public var explanation: String {
        (state == .ready ? "Git · disk and index" : state.explanation) +
            (snapshot.map { " · " + $0.repository.root } ?? "")
            + (snapshot != nil && state != .ready ? " · previous snapshot" : "")
            + (liveUpdatesAvailable == false ? " · live updates unavailable; use Refresh" : "")
    }

    public func viewHistory(of branch: GitBranch) {
        guard state == .ready else { return }

        historyTask?.cancel()
        filesTask?.cancel()
        commitID = UUID()
        revision = branch.oid
        customHistory = true
        historyTitle = branch.name
        resetHistory()
        loadMoreHistory()
    }

    public func loadMoreHistory() {
        guard !stopped, state == .ready, historyState != .loading, let repository = snapshot?.repository,
              let revision else {
            return
        }

        let token = epoch, start = history.count
        historyState = .loading
        changed()
        historyTask = Task { [weak self, service] in
            do {
                let page = try await service.history(in: repository, revision: revision, offset: start, count: 50)
                guard let self, !Task.isCancelled, epoch == token, self.revision == revision, !stopped else { return }

                history += page.commits
                hasMoreHistory = page.hasMore
                historyState = .ready
            } catch {
                guard let self, !Task.isCancelled, epoch == token, self.revision == revision, !stopped else { return }

                historyState = Self.failure(error)
            }
            self?.changed()
        }
    }

    public func select(_ commit: GitCommit) {
        guard !stopped, state == .ready, let repository = snapshot?.repository else { return }

        selectedCommit = commit
        commitFiles = []
        filesState = .loading
        filesTask?.cancel()
        commitID = UUID()
        let token = commitID, generation = epoch
        changed()
        filesTask = Task { [weak self, service] in
            do {
                let values = try await service.files(in: repository, commit: commit)
                guard let self, !Task.isCancelled, epoch == generation, commitID == token, !stopped else { return }

                commitFiles = values
                filesState = .ready
            } catch {
                guard let self, !Task.isCancelled, epoch == generation, commitID == token, !stopped else { return }

                filesState = Self.failure(error)
            }
            self?.changed()
        }
    }

    public func inspect(_ comparison: GitComparison) {
        requestDiff(comparison, openTab: true)
    }

    private func requestDiff(_ comparison: GitComparison, openTab: Bool) {
        guard !stopped, state == .ready, let repository = snapshot?.repository else { return }

        let changedComparison = self.comparison != comparison
        self.comparison = comparison
        diffTask?.cancel()
        diffID = UUID()
        let token = diffID, generation = epoch
        diffState = .loading
        if changedComparison || openTab { diffText = "Loading diff…" }
        changed()
        if openTab { onInspect?() }
        diffTask = Task { [weak self, service] in
            do {
                let text = try await service.diff(in: repository, comparison: comparison)
                guard let self, !Task.isCancelled, epoch == generation, diffID == token, !stopped else { return }

                diffText = text.isEmpty ? "No differences on disk for this comparison." : text
                diffState = .ready
            } catch {
                guard let self, !Task.isCancelled, epoch == generation, diffID == token, !stopped else { return }

                diffState = Self.failure(error)
                diffText = diffState.explanation
            }
            self?.changed()
        }
    }

    public func perform(_ action: GitLocalAction) {
        guard canMutate, let expected = snapshot, let mutations else { return }

        refreshTask?.cancel()
        scheduledRefresh?.cancel()
        operationID = UUID()
        let token = operationID
        operationTitle = action.title
        operationOutput = ""
        operationState = action.changesCheckout ? .preparing : .running
        changed()
        let prepare = prepareCheckout, finish = checkoutFinished
        operationTask = Task { [weak self, service] in
            var prepared = false
            defer { if prepared { finish?(expected.repository) } }
            do {
                var reviewed = expected
                if action.changesCheckout {
                    guard let prepare, await prepare(expected.repository) else { throw CancellationError() }

                    prepared = true
                    try Task.checkCancellation()
                    reviewed = try await service.snapshot(at: expected.repository.root)
                    guard reviewed.repository == expected.repository, reviewed.head == expected.head,
                          reviewed.branch == expected.branch else {
                        throw GitInspectionError.failed("Checkout changed while saving documents; review and retry")
                    }
                }

                try Task.checkCancellation()
                guard let self, !stopped, operationID == token else { return }

                operationState = .running
                changed()
                try await mutations.perform(action, expected: reviewed) { [weak self] chunk in
                    Task { @MainActor [weak self] in
                        guard let self, !self.stopped, self.operationID == token else { return }

                        self.operationOutput = String((self.operationOutput + chunk).suffix(32_000))
                        self.changed()
                    }
                }
                guard !stopped, operationID == token else { return }

                operationState = Task.isCancelled ? .cancelled : .succeeded
                if !Task.isCancelled, case .fetch(let remote) = action { lastFetch = (remote, .now) }
            } catch {
                guard let self, !stopped, operationID == token else { return }

                operationState = error is CancellationError || Task.isCancelled
                    ? .cancelled
                    : .failed(error.localizedDescription)
            }
            guard let self, !stopped, operationID == token else { return }

            operationTask = nil
            changed()
            refresh()// Failure/cancellation may still have changed Git. Never claim rollback.
        }
    }

    public func cancelOperation() {
        guard operationState.isBusy else { return }

        operationState = .cancelling
        operationTask?.cancel()
        changed()
    }

    public func stop() {
        stopped = true
        epoch = UUID()
        diffID = UUID()
        commitID = UUID()
        refreshTask?.cancel()
        historyTask?.cancel()
        diffTask?.cancel()
        filesTask?.cancel()
        scheduledRefresh?.cancel()
        operationTask?.cancel()
        onInspect = nil
        prepareCheckout = nil
        checkoutFinished = nil
    }

    private func resetHistory() {
        history = []
        selectedCommit = nil
        commitFiles = []
        hasMoreHistory = false
        historyState = .idle
        filesState = .idle
    }

    private static func failure(_ error: any Error) -> GitLoadState {
        if case GitInspectionError.unavailable(let reason) = error { return .unavailable(reason) }

        return .failed(error.localizedDescription)
    }

    @discardableResult
    public func subscribe(_ observer: @escaping () -> Void) -> UUID {
        let id = UUID()
        observers[id] = observer

        return id
    }

    public func unsubscribe(_ id: UUID) { observers[id] = nil }

    private func changed() { for observer in Array(observers.values) { observer() } }
}
