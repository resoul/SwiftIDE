import Foundation

public enum GitManagementKind: String, CaseIterable, Sendable {
    case renameBranch = "Rename local branch", deleteBranch = "Delete local branch"
    case addRemote = "Add remote", editRemote = "Change remote URL", removeRemote = "Remove remote"
    case createTag = "Create tag", deleteTag = "Delete local tag"
    case deleteRemoteBranch = "Delete remote branch", deleteRemoteTag = "Delete remote tag"
    public var isNetwork: Bool { self == .deleteRemoteBranch || self == .deleteRemoteTag }
}

public struct GitManagementRequest: Equatable, Sendable {
    public let kind: GitManagementKind
    public let name: String
    public let value: String
    public let message: String
    public let allowUnmerged: Bool

    public init(
        kind: GitManagementKind,
        name: String,
        value: String = "",
        message: String = "",
        allowUnmerged: Bool = false
    ) {
        self.kind = kind
        self.name = name
        self.value = value
        self.message = message
        self.allowUnmerged = allowUnmerged
    }
}

public struct GitManagementPlan: Equatable, Sendable {
    public let repository: GitRepository
    public let request: GitManagementRequest
    public let token: String
    public let oid: String?
    public let url: String?
    public let summary: String
    public var title: String { request.kind.rawValue + " · " + request.name }

    public init(
        repository: GitRepository,
        request: GitManagementRequest,
        token: String,
        oid: String?,
        url: String?,
        summary: String
    ) {
        self.repository = repository
        self.request = request
        self.token = token
        self.oid = oid
        self.url = url
        self.summary = summary
    }
}

public protocol GitManagementPlanning: Sendable {
    func planManagement(in snapshot: GitSnapshot, request: GitManagementRequest) async throws -> GitManagementPlan
}

@MainActor
public final class GitManagementReview {
    public let workspace: GitWorkspace
    public private(set) var state = GitLoadState.idle
    public private(set) var plan: GitManagementPlan?
    private var generation = UUID()
    private var task: Task<Void, Never>?
    private var stopped = false
    private var subscription: UUID?
    private var observers: [UUID: () -> Void] = [:]
    private var reviewedSnapshot: GitSnapshot?
    public var canApply: Bool { !stopped && state == .ready && workspace.canMutate && plan != nil }

    public init(workspace: GitWorkspace) {
        self.workspace = workspace
        subscription = workspace.subscribe { [weak self] in
            guard let self else { return }

            if let old = reviewedSnapshot, let current = workspace.snapshot,
               current.repository != old.repository || current.mutationToken != old.mutationToken || current
               .branches != old.branches
               || current.tags != old.tags || current.remotes != old.remotes {
                invalidate()
            }

            changed()
        }
    }

    public func invalidate() {
        task?.cancel()
        generation = UUID()
        plan = nil
        reviewedSnapshot = nil
        state = .idle
        changed()
    }

    public func review(_ request: GitManagementRequest) {
        guard !stopped, workspace.canMutate, let snapshot = workspace.snapshot,
              let planner = workspace.managementPlanner else {
            return
        }

        invalidate()
        state = .loading
        reviewedSnapshot = snapshot
        changed()
        let token = generation
        task = Task { [weak self] in
            do {
                let value = try await planner.planManagement(in: snapshot, request: request)
                try Task.checkCancellation()
                guard let self, !stopped, token == generation else { return }

                plan = value
                state = .ready
                changed()
            } catch {
                guard let self, !stopped, token == generation else { return }

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
