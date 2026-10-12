import Foundation

public enum GitReplayAction: String, CaseIterable, Sendable { case pick, squash, fixup, edit, drop }

public struct GitReplayStep: Equatable, Sendable {
    public let commit: GitCommit
    public var action: GitReplayAction

    public init(commit: GitCommit, action: GitReplayAction = .pick) {
        self.commit = commit
        self.action = action
    }
}

public struct GitInteractiveRebasePlan: Equatable, Sendable {
    public let source: GitIntegrationPlan
    public let commits: [GitCommit]
    public let token: String
    public var steps: [GitReplayStep]

    public init(source: GitIntegrationPlan, commits: [GitCommit], token: String) {
        self.source = source
        self.commits = commits
        self.token = token
        steps = commits.map { GitReplayStep(commit: $0) }
    }

    public var validation: String? {
        guard !commits.isEmpty, commits.count <= 200, steps.count == commits.count,
              Set(steps.map(\.commit.oid)).count == commits.count,
              Set(steps.map(\.commit.oid)) == Set(commits.map(\.oid)),
              steps.allSatisfy({ commits.contains($0.commit) }) else {
            return "The plan must contain each reviewed commit exactly once (up to 200 commits)."
        }

        var precedingCommit = false
        for step in steps {
            if step.action == .squash || step.action == .fixup {
                guard precedingCommit else { return "Squash/Fixup needs a preceding retained commit." }
            }

            if step.action != .drop { precedingCommit = true }
        }

        return nil
    }
}

public protocol GitInteractiveRebasePlanning: Sendable {
    func planInteractiveRebase(in snapshot: GitSnapshot, target: GitBranch) async throws -> GitInteractiveRebasePlan
}

@MainActor
public final class GitInteractiveRebaseReview {
    public let workspace: GitWorkspace
    public private(set) var state = GitLoadState.idle
    public private(set) var plan: GitInteractiveRebasePlan?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var stopped = false
    private var subscription: UUID?
    private var observers: [UUID: () -> Void] = [:]
    private var snapshot: GitSnapshot?

    public init(workspace: GitWorkspace) {
        self.workspace = workspace
        subscription = workspace.subscribe { [weak self] in
            guard let self else { return }

            if let old = snapshot, let current = workspace.snapshot,
               old.repository != current.repository || old.mutationToken != current.mutationToken
               || old.head != current.head || old.branch != current.branch || old.branches != current.branches {
                invalidate()
            }

            changed()
        }
    }

    public var canApply: Bool {
        !stopped && state == .ready && workspace.canMutate && plan != nil && plan?.validation == nil
    }

    public func invalidate() {
        task?.cancel()
        generation = UUID()
        plan = nil
        snapshot = nil
        state = .idle
        changed()
    }

    public func review(target: GitBranch) {
        guard !stopped, workspace.canMutate, let current = workspace.snapshot,
              let planner = workspace.interactiveRebasePlanner else { return }

        invalidate()
        snapshot = current
        state = .loading
        changed()
        let id = generation
        task = Task { [weak self] in
            do {
                let value = try await planner.planInteractiveRebase(in: current, target: target)
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

    public func setAction(_ action: GitReplayAction, at index: Int) {
        guard plan?.steps.indices.contains(index) == true else { return }

        plan?.steps[index].action = action
        changed()
    }

    public func move(from: Int, to: Int) {
        guard plan?.steps.indices.contains(from) == true, plan?.steps.indices.contains(to) == true else { return }

        guard var value = plan else { return }

        let step = value.steps.remove(at: from)
        value.steps.insert(step, at: to)
        plan = value
        changed()
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
