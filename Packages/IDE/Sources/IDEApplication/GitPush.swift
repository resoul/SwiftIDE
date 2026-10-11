import Foundation

public struct GitPushPlan: Equatable, Sendable {
    public let repository: GitRepository
    public let branch: GitBranch
    public let remote: String
    public let destination: String
    public let url: String

    public init(repository: GitRepository, branch: GitBranch, remote: String, destination: String, url: String) {
        self.repository = repository; self.branch = branch; self.remote = remote; self.destination = destination; self.url = url
    }

    public var title: String { "Push " + branch.name + " → " + remote + "/" + destination }
}

public protocol GitPushPlanning: Sendable {
    func planPush(in snapshot: GitSnapshot, branch: GitBranch, remote: String, destination: String) async throws -> GitPushPlan
}

/// Reviewing a destination is read-only. Only the explicit Push button starts a workspace action.
@MainActor
public final class GitPushReview {
    public let workspace: GitWorkspace
    public private(set) var state = GitLoadState.idle
    public private(set) var submittedPlan: GitPushPlan?
    public private(set) var plan: GitPushPlan?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var stopped = false
    public private(set) var operationStarted = false
    private var activePush = false
    private var subscription: UUID?
    private var observers: [UUID: () -> Void] = [:]
    public var canPush: Bool { plan != nil && state == .ready && workspace.canMutate && !stopped }

    public init(workspace: GitWorkspace) {
        self.workspace = workspace
        subscription = workspace.subscribe { [weak self] in self?.workspaceChanged() }
    }

    public func invalidate() {
        task?.cancel(); generation = UUID(); plan = nil; state = .idle; changed()
    }
    public func review(branch: GitBranch, remote: String, destination: String) {
        guard !stopped, workspace.canMutate, let snapshot = workspace.snapshot, let planner = workspace.pushPlanner else { return }

        invalidate(); state = .loading; changed()
        let token = generation
        task = Task { [weak self] in
            do {
                let value = try await planner.planPush(in: snapshot, branch: branch, remote: remote, destination: destination)
                try Task.checkCancellation()
                guard let self, !stopped, generation == token else { return }

                guard workspace.snapshot?.repository == value.repository,
                      workspace.snapshot?.branches.contains(value.branch) == true,
                      workspace.snapshot?.remotes.contains(value.remote) == true else {
                    throw GitInspectionError.failed("Source branch changed while reviewing; review again")
                }

                plan = value; state = .ready
            } catch {
                guard let self, !stopped, generation == token, !Task.isCancelled else { return }

                plan = nil; state = .failed(error.localizedDescription)
            }
            self?.task = nil; self?.changed()
        }
    }
    public func push() {
        guard canPush, let plan else { return }

        submittedPlan = plan
        activePush = true; operationStarted = true
        self.plan = nil; state = .idle
        workspace.perform(.push(plan)); changed()
    }
    private func workspaceChanged() {
        if activePush, !workspace.operationState.isBusy { activePush = false }
        if let plan, workspace.snapshot?.repository != plan.repository || workspace.snapshot?.branches.contains(plan.branch) != true || workspace.snapshot?.remotes.contains(plan.remote) != true {
            invalidate()
        }

        changed()
    }
    public func stop() {
        stopped = true; task?.cancel(); generation = UUID()
        if activePush { workspace.cancelOperation() }
        if let subscription { workspace.unsubscribe(subscription) }; subscription = nil
    }
    @discardableResult public func subscribe(_ observer: @escaping () -> Void) -> UUID {
        let id = UUID(); observers[id] = observer; return id
    }
    public func unsubscribe(_ id: UUID) { observers[id] = nil }
    private func changed() { for observer in Array(observers.values) { observer() } }
}
