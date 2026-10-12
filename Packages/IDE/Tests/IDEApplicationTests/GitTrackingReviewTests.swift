import Foundation
import IDEApplication
import Testing

private actor DelayedTrackingService: GitInspecting, GitMutating, GitTrackingPlanning {
    let source = GitBranch(reference: "refs/remotes/origin/main", oid: String(repeating: "a", count: 40))
    private var requests: [(GitSnapshot, GitTrackingRequest, CheckedContinuation<GitTrackingPlan, Never>)] = []
    var count: Int { requests.count }

    func snapshot(at projectRoot: String) async throws -> GitSnapshot {
        .init(
            repository: .init(
                root: projectRoot,
                gitDirectory: projectRoot + "/.git",
                commonDirectory: projectRoot + "/.git"
            ),
            branch: "main",
            head: source.oid,
            changes: [],
            branches: [source],
            remotes: ["origin"]
        )
    }

    func planTracking(in snapshot: GitSnapshot, request: GitTrackingRequest) async throws -> GitTrackingPlan {
        await withCheckedContinuation { requests.append((snapshot, request, $0)) }
    }

    func finish(_ index: Int) {
        let (snapshot, request, continuation) = requests[index]
        continuation.resume(returning: .init(
            repository: snapshot.repository,
            request: request,
            remote: "origin",
            remoteSource: "refs/heads/main",
            configurationToken: "fixture"
        ))
    }

    func perform(
        _ action: GitLocalAction,
        expected: GitSnapshot,
        output: @escaping @Sendable (String) -> Void
    ) async throws {}

    func history(
        in repository: GitRepository,
        revision: String,
        offset: Int,
        count: Int
    ) async throws -> GitHistoryPage { .init(
        commits: [],
        hasMore: false
    ) }

    func files(in repository: GitRepository, commit: GitCommit) async throws -> [GitCommitFile] { [] }

    func diff(in repository: GitRepository, comparison: GitComparison) async throws -> String { "" }
}

@MainActor
struct GitTrackingReviewTests {
    private func wait(_ predicate: () async -> Bool) async throws {
        let end = ContinuousClock.now + .seconds(5)
        while !(await predicate()), ContinuousClock.now < end { await Task.yield() }
        try #require(await predicate())
    }

    @Test func replacedAndStoppedReviewsCannotPublishLatePlans() async throws {
        let service = DelayedTrackingService(), workspace = GitWorkspace(root: "/repo", service: service)
        let model = GitTrackingReview(workspace: workspace)
        defer {
            model.stop()
            workspace.stop()
        }
        workspace.refresh()
        try await wait { workspace.canMutate }
        let source = service.source
        model.review(.create(name: "old", source: source))
        try await wait { await service.count == 1 }
        model.invalidate()
        model.review(.create(name: "new", source: source))
        try await wait { await service.count == 2 }
        await service.finish(1)
        try await wait { model.canApply }
        await service.finish(0)
        for _ in 0..<10 { await Task.yield() }
        #expect(model.plan?.request.name == "new")
        model.review(.create(name: "closed", source: source))
        try await wait { await service.count == 3 }
        model.stop()
        await service.finish(2)
        for _ in 0..<10 { await Task.yield() }
        #expect(model.plan == nil && !model.canApply && model.state == .idle)
    }
}
