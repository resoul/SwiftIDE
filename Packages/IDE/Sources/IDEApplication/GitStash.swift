import Foundation

public struct GitStashEntry: Equatable, Sendable {
    public let selector: String
    public let oid: String
    public let date: Date
    public let message: String
    public var key: String { selector + " " + oid }

    public init(selector: String, oid: String, date: Date, message: String) {
        self.selector = selector
        self.oid = oid
        self.date = date
        self.message = message
    }
}

public struct GitStashList: Equatable, Sendable {
    public let entries: [GitStashEntry]
    public let token: String
    public let hasMore: Bool

    public init(entries: [GitStashEntry], token: String, hasMore: Bool = false) {
        self.entries = entries
        self.token = token
        self.hasMore = hasMore
    }
}

public enum GitStashInclusion: String, CaseIterable, Sendable {
    case tracked = "Tracked files only"
    case untracked = "Include untracked files"
    case ignored = "Include untracked AND ignored files"
}

public enum GitStashRequest: Equatable, Sendable {
    case create(message: String, inclusion: GitStashInclusion)
    case apply(GitStashEntry, restoreIndex: Bool)
    case pop(GitStashEntry, restoreIndex: Bool)
    case drop(GitStashEntry)

    public var entry: GitStashEntry? {
        switch self {
        case .create: nil
        case .apply(let entry, _), .pop(let entry, _), .drop(let entry): entry
        }
    }
    public var title: String {
        switch self {
        case .create: "Create stash"
        case .apply: "Apply stash"
        case .pop: "Pop stash"
        case .drop: "Drop stash"
        }
    }
    public var changesCheckout: Bool {
        if case .drop = self { return false }

        return true
    }
}

public struct GitStashPlan: Equatable, Sendable {
    public let repository: GitRepository
    public let head: String
    public let branch: String?
    public let listToken: String
    public let request: GitStashRequest

    public init(
        repository: GitRepository,
        head: String,
        branch: String?,
        listToken: String,
        request: GitStashRequest
    ) {
        self.repository = repository
        self.head = head
        self.branch = branch
        self.listToken = listToken
        self.request = request
    }
}

public protocol GitStashReading: Sendable {
    func stashes(in repository: GitRepository) async throws -> GitStashList
}

/// A bounded stash browser and explicit review, independent of editor/window ownership.
@MainActor
public final class GitStashes {
    public let workspace: GitWorkspace
    public private(set) var state = GitLoadState.idle
    public private(set) var list: GitStashList?
    public private(set) var plan: GitStashPlan?
    public private(set) var reviewError: String?
    public var canStart: Bool { plan != nil && canReview }
    public var canInspect: Bool {
        !stopped && state == .ready && workspace.state == .ready && !workspace.operationState.isBusy
    }
    public var canReview: Bool {
        !stopped && state == .ready && workspace.canMutate && workspace.snapshot?.head != nil
            && workspace.snapshot?.integration == nil
            && workspace.snapshot?.changes.contains(where: { $0.decoration.isConflict }) == false
    }
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var stopped = false
    private var subscription: UUID?
    private var capturedAt: Date?
    private var observers: [UUID: () -> Void] = [:]

    public init(workspace: GitWorkspace) {
        self.workspace = workspace
        subscription = workspace.subscribe { [weak self] in self?.workspaceChanged() }
        workspaceChanged()
    }

    private func workspaceChanged() {
        if workspace.state != .ready || workspace.operationState.isBusy { plan = nil }
        if let snapshot = workspace.snapshot, workspace.state == .ready,
           !workspace.operationState.isBusy, capturedAt != snapshot.capturedAt {
            capturedAt = snapshot.capturedAt
            refresh()
        }

        changed()
    }

    public func invalidate() {
        plan = nil
        reviewError = nil
        changed()
    }

    public func review(_ request: GitStashRequest) {
        guard canReview, let list, let snapshot = workspace.snapshot, let head = snapshot.head else { return }

        plan = nil
        reviewError = nil
        if let entry = request.entry, !list.entries.contains(entry) {
            reviewError = "Stash selection changed; Refresh and Review again."
        } else if case .create(let message, _) = request, message.contains("\0") || message.utf8.count > 16_000 {
            reviewError = "Stash message must be at most 16 KB and contain no NUL."
        } else {
            plan = .init(
                repository: snapshot.repository,
                head: head,
                branch: snapshot.branch,
                listToken: list.token,
                request: request
            )
        }

        changed()
    }

    public func refresh() {
        guard !stopped, workspace.state == .ready, !workspace.operationState.isBusy,
              let repository = workspace.snapshot?.repository, let reader = workspace.stashReader else { return }

        task?.cancel()
        generation = UUID()
        let token = generation
        plan = nil
        reviewError = nil
        state = .loading
        changed()
        task = Task { [weak self] in
            do {
                let value = try await reader.stashes(in: repository)
                try Task.checkCancellation()
                guard let self, !stopped, generation == token,
                      workspace.snapshot?.repository == repository else { return }

                list = value
                state = .ready
            } catch {
                guard let self, !stopped, generation == token, !Task.isCancelled else { return }

                state = .failed(error.localizedDescription)
            }
            self?.task = nil
            self?.changed()
        }
    }

    public func stop() {
        stopped = true
        generation = UUID()
        task?.cancel()
        plan = nil
        if let subscription { workspace.unsubscribe(subscription) }
        subscription = nil
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
