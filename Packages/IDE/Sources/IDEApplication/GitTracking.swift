import Foundation

public enum GitTrackingRequest: Equatable, Sendable {
    case create(name: String, source: GitBranch)
    case set(branch: GitBranch, target: GitBranch)
    case remove(branch: GitBranch)

    public var name: String {
        switch self {
        case .create(let name, _): name
        case .set(let branch, _), .remove(let branch): branch.name
        }
    }
    public var source: GitBranch? {
        switch self {
        case .create(_, let source), .set(_, let source): source
        case .remove: nil
        }
    }
}

public struct GitTrackingPlan: Equatable, Sendable {
    public let repository: GitRepository
    public let request: GitTrackingRequest
    public let remote: String?
    public let remoteSource: String?
    public let configurationToken: String

    public init(
        repository: GitRepository,
        request: GitTrackingRequest,
        remote: String?,
        remoteSource: String?,
        configurationToken: String
    ) {
        self.repository = repository
        self.request = request
        self.remote = remote
        self.remoteSource = remoteSource
        self.configurationToken = configurationToken
    }

    public var title: String {
        switch request {
        case .create: "Create tracking branch " + request.name
        case .set: "Set upstream for " + request.name
        case .remove: "Remove upstream for " + request.name
        }
    }
}

public protocol GitTrackingPlanning: Sendable {
    func planTracking(in snapshot: GitSnapshot, request: GitTrackingRequest) async throws -> GitTrackingPlan
}

/// Review only. The owning host submits the returned immutable plan explicitly.
@MainActor
public final class GitTrackingReview {
    public let workspace: GitWorkspace
    public private(set) var state = GitLoadState.idle
    public private(set) var plan: GitTrackingPlan?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var stopped = false
    private var subscription: UUID?
    private var observers: [UUID: () -> Void] = [:]
    public var canApply: Bool { !stopped && workspace.canMutate && state == .ready && plan != nil }

    public init(workspace: GitWorkspace) {
        self.workspace = workspace
        subscription = workspace.subscribe { [weak self] in
            guard let self else { return }

            if let plan, !matches(plan) { invalidate() }
            changed()
        }
    }

    public func invalidate() {
        task?.cancel()
        generation = UUID()
        plan = nil
        state = .idle
        changed()
    }

    public func review(_ request: GitTrackingRequest) {
        guard !stopped, workspace.canMutate, let snapshot = workspace.snapshot,
              let planner = workspace.trackingPlanner else { return }

        invalidate()
        state = .loading
        changed()
        let token = generation
        task = Task { [weak self] in
            do {
                let value = try await planner.planTracking(in: snapshot, request: request)
                try Task.checkCancellation()
                guard let self, !stopped, token == generation else { return }

                guard matches(value) else { throw GitInspectionError.failed("Branches changed; Review again.") }

                plan = value
                state = .ready
            } catch {
                guard let self, !stopped, token == generation, !Task.isCancelled else { return }

                state = .failed(error.localizedDescription)
            }
            self?.task = nil
            self?.changed()
        }
    }

    private func matches(_ plan: GitTrackingPlan) -> Bool {
        guard let snapshot = workspace.snapshot, snapshot.repository == plan.repository,
              snapshot.integration == nil else { return false }

        if let source = plan.request.source, !snapshot.branches.contains(source) { return false }
        if let remote = plan.remote, !snapshot.remotes.contains(remote) { return false }

        switch plan.request {
        case .create(let name, _): return !snapshot.branches.contains { $0.reference == "refs/heads/" + name }
        case .set(let branch, _), .remove(let branch): return snapshot.branches.contains(branch)
        }
    }

    public func stop() {
        stopped = true
        invalidate()
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
