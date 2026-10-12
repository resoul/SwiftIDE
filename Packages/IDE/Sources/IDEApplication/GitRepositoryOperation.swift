import Foundation

public enum GitRepositoryOperationKind: String, CaseIterable, Sendable {
    case discard = "Discard saved worktree changes"
    case resetSoft = "Reset branch (keep index and disk)"
    case resetMixed = "Reset branch and index (keep disk)"
    case resetHard = "Reset branch, index and disk"
    case cherryPick = "Cherry-pick commit", revert = "Revert commit"
    case fetch = "Fetch with tags/prune options"
    case updateSubmodule = "Initialize/update submodule", syncSubmodule = "Sync submodule URL"
    case addSubmodule = "Add submodule", removeSubmodule = "Remove submodule (stage deletion)"
    case deinitSubmodule = "Deinitialize submodule (keep Git objects)"
    public var isSubmodule: Bool {
        [.updateSubmodule, .syncSubmodule, .addSubmodule, .removeSubmodule, .deinitSubmodule].contains(self)
    }
    public var changesCheckout: Bool {
        [
            .discard,
            .resetHard,
            .cherryPick,
            .revert,
            .updateSubmodule,
            .addSubmodule,
            .removeSubmodule,
            .deinitSubmodule
        ].contains(self)
    }
}

public struct GitRepositoryOperationRequest: Equatable, Sendable {
    public let kind: GitRepositoryOperationKind
    public let value: String
    public let mainline: Int
    public let tags: Bool
    public let prune: Bool
    public let url: String

    public init(
        kind: GitRepositoryOperationKind,
        value: String,
        mainline: Int = 0,
        tags: Bool = false,
        prune: Bool = false,
        url: String = ""
    ) {
        self.kind = kind
        self.value = value
        self.mainline = mainline
        self.tags = tags
        self.prune = prune
        self.url = url
    }
}

public struct GitRepositoryOperationPlan: Equatable, Sendable {
    public let repository: GitRepository
    public let request: GitRepositoryOperationRequest
    public let head: String
    public let branch: String?
    public let target: String?
    public let url: String?
    public let submoduleName: String?
    public let token: String
    public let summary: String

    public init(
        repository: GitRepository,
        request: GitRepositoryOperationRequest,
        head: String,
        branch: String?,
        target: String? = nil,
        url: String? = nil,
        submoduleName: String? = nil,
        token: String,
        summary: String
    ) {
        self.repository = repository
        self.request = request
        self.head = head
        self.branch = branch
        self.target = target
        self.url = url
        self.submoduleName = submoduleName
        self.token = token
        self.summary = summary
    }
}

public protocol GitRepositoryOperationPlanning: Sendable {
    func planRepositoryOperation(in snapshot: GitSnapshot, request: GitRepositoryOperationRequest) async throws
        -> GitRepositoryOperationPlan
}

@MainActor
public final class GitRepositoryOperationReview {
    public let workspace: GitWorkspace
    public private(set) var state = GitLoadState.idle
    public private(set) var plan: GitRepositoryOperationPlan?
    private var snapshot: GitSnapshot?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var stopped = false
    private var subscription: UUID?
    private var observers: [UUID: () -> Void] = [:]

    public init(workspace: GitWorkspace) {
        self.workspace = workspace
        subscription = workspace.subscribe { [weak self] in
            guard let self else { return }

            if let previous = snapshot, let current = workspace.snapshot,
               previous.repository != current.repository || previous.mutationToken != current.mutationToken
               || previous.head != current.head || previous.branch != current.branch
               || previous.branches != current.branches || previous.remotes != current.remotes { invalidate() }

            changed()
        }
    }

    public var canApply: Bool { !stopped && state == .ready && workspace.canMutate && plan != nil }

    public func invalidate() {
        task?.cancel()
        generation = UUID()
        plan = nil
        snapshot = nil
        state = .idle
        changed()
    }

    public func review(_ request: GitRepositoryOperationRequest) {
        guard !stopped, workspace.canMutate, let current = workspace.snapshot,
              let planner = workspace.repositoryOperationPlanner else { return }

        invalidate()
        snapshot = current
        state = .loading
        changed()
        let id = generation
        task = Task { [weak self] in
            do {
                let value = try await planner.planRepositoryOperation(in: current, request: request)
                try Task.checkCancellation()
                guard let self, !stopped, generation == id else { return }

                plan = value
                state = .ready
                changed()
            } catch {
                guard let self, !stopped, generation == id else { return }

                state = .failed(error.localizedDescription)
                changed()
            }
        }
    }

    public func stop() {
        stopped = true
        invalidate()
        if let subscription { workspace.unsubscribe(subscription) }
        observers = [:]
    }

    @discardableResult public func subscribe(_ observer: @escaping () -> Void) -> UUID {
        let id = UUID()
        observers[id] = observer

        return id
    }

    public func unsubscribe(_ id: UUID) { observers[id] = nil }

    private func changed() { for callback in Array(observers.values) { callback() } }
}
