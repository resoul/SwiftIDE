import Foundation

public struct GitPullDivergence: Equatable, Sendable {
    public let repository: GitRepository
    public let head: String
    public let target: GitBranch

    public init(repository: GitRepository, head: String, target: GitBranch) {
        self.repository = repository
        self.head = head
        self.target = target
    }
}

public struct GitPullPlan: Equatable, Sendable {
    public let repository: GitRepository
    public let branch: GitBranch
    public let remote: String
    public let source: String
    public let url: String

    public init(repository: GitRepository, branch: GitBranch, remote: String, source: String, url: String) {
        self.repository = repository
        self.branch = branch
        self.remote = remote
        self.source = source
        self.url = url
    }

    public var title: String { "Pull " + remote + "/" + source + " → " + branch.name + " (fast-forward only)" }
}

public protocol GitPullPlanning: Sendable {
    func planPull(in snapshot: GitSnapshot, remote: String, source: String) async throws -> GitPullPlan
}

/// Reviewing a fetch source is read-only. Only the explicit Pull button starts a workspace action.
@MainActor
public final class GitPullReview {
    public let workspace: GitWorkspace
    public private(set) var state = GitLoadState.idle
    public private(set) var submittedPlan: GitPullPlan?
    public private(set) var plan: GitPullPlan?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var stopped = false
    public private(set) var operationStarted = false
    private var activePull = false
    private var subscription: UUID?
    private var observers: [UUID: () -> Void] = [:]
    public var canPull: Bool { plan != nil && state == .ready && workspace.canMutate && !stopped }

    public init(workspace: GitWorkspace) {
        self.workspace = workspace
        subscription = workspace.subscribe { [weak self] in self?.workspaceChanged() }
    }

    public func invalidate() {
        task?.cancel()
        generation = UUID()
        plan = nil
        state = .idle
        changed()
    }

    public func review(remote: String, source: String) {
        guard !stopped, workspace.canMutate, let snapshot = workspace.snapshot,
              let planner = workspace.pullPlanner else {
            return
        }

        invalidate()
        state = .loading
        changed()
        let token = generation
        task = Task { [weak self] in
            do {
                let value = try await planner.planPull(in: snapshot, remote: remote, source: source)
                try Task.checkCancellation()
                guard let self, !stopped, generation == token else { return }

                guard workspace.snapshot?.repository == value.repository,
                      workspace.snapshot?.branches.contains(value.branch) == true,
                      workspace.snapshot?.branch == value.branch.name,
                      workspace.snapshot?.remotes.contains(value.remote) == true else {
                    throw GitInspectionError.failed("Source branch changed while reviewing; review again")
                }

                plan = value
                state = .ready
            } catch {
                guard let self, !stopped, generation == token, !Task.isCancelled else { return }

                plan = nil
                state = .failed(error.localizedDescription)
            }
            self?.task = nil
            self?.changed()
        }
    }

    public func pull() {
        guard canPull, let plan else { return }

        submittedPlan = plan
        activePull = true
        operationStarted = true
        self.plan = nil
        state = .idle
        workspace.perform(.pull(plan))
        changed()
    }

    private func workspaceChanged() {
        if activePull, !workspace.operationState.isBusy { activePull = false }
        if let plan,
           workspace.snapshot?.branch != plan.branch.name || workspace.snapshot?.repository != plan
           .repository || workspace.snapshot?.branches.contains(plan.branch) != true || workspace.snapshot?.remotes
           .contains(plan.remote) != true {
            invalidate()
        }

        changed()
    }

    public func stop() {
        stopped = true
        task?.cancel()
        generation = UUID()
        if activePull { workspace.cancelOperation() }
        if let subscription { workspace.unsubscribe(subscription) }
        subscription = nil
    }

    @discardableResult public func subscribe(_ observer: @escaping () -> Void) -> UUID {
        let id = UUID()
        observers[id] = observer

        return id
    }

    public func unsubscribe(_ id: UUID) { observers[id] = nil }

    private func changed() { for observer in Array(observers.values) { observer() } }
}
