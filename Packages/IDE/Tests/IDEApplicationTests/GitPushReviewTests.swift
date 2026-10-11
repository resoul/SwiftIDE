import Foundation
import Testing
@testable import IDEApplication

@Suite(.serialized) @MainActor
struct GitPushReviewTests {
    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        try #require(predicate())
    }
    @Test func reviewDoesNotWriteAndOnlyExplicitPushStartsOnceWithoutCheckout() async throws {
        let service = PushReviewFixture(), workspace = GitWorkspace(root: "/repo", service: service), model = GitPushReview(workspace: workspace)
        defer { model.stop(); workspace.stop() }
        workspace.refresh(); try await wait { workspace.canMutate }
        var prepared = false; workspace.prepareCheckout = { _ in prepared = true; return true }
        model.review(branch: PushReviewFixture.branch, remote: "origin", destination: "reviewed")
        try await wait { model.state == .ready }
        #expect(await service.writes == 0 && model.canPush)
        model.push(); model.push()
        try await wait { workspace.operationState == .succeeded && workspace.canMutate }
        #expect(await service.writes == 1 && !prepared && !model.canPush)
        #expect(await service.sent?.destination == "reviewed")
        #expect(workspace.lastFetch == nil)
        await service.failNext()
        model.review(branch: PushReviewFixture.branch, remote: "origin", destination: "reviewed")
        try await wait { model.state == .ready }; model.push()
        try await wait { workspace.operationState == .failed("Rejected by remote") && workspace.canMutate }
        #expect(!model.canPush)
    }
    @Test func inputChangesOwnerStopAndMovedBranchRejectLateReview() async throws {
        let service = PushReviewFixture(), workspace = GitWorkspace(root: "/repo", service: service), model = GitPushReview(workspace: workspace)
        defer { model.stop(); workspace.stop() }
        workspace.refresh(); try await wait { workspace.canMutate }
        await service.holdReview()
        model.review(branch: PushReviewFixture.branch, remote: "origin", destination: "old")
        try await wait { model.state == .loading }; try await service.waitForReview()
        model.invalidate(); await service.completeReview()
        for _ in 0..<20 { await Task.yield() }
        #expect(model.plan == nil && model.state == .idle)
        model.review(branch: PushReviewFixture.branch, remote: "origin", destination: "new")
        try await wait { model.state == .ready }
        await service.moveBranch(); workspace.refresh(); try await wait { workspace.canMutate }
        #expect(!model.canPush && model.plan == nil)
        await service.holdReview()
        let branch = try #require(workspace.snapshot?.branches.first)
        model.review(branch: branch, remote: "origin", destination: "late")
        try await service.waitForReview(); model.stop(); await service.completeReview()
        for _ in 0..<20 { await Task.yield() }
        #expect(model.plan == nil && !model.canPush)
    }
}

private actor PushReviewFixture: GitInspecting, GitMutating, GitPushPlanning {
    static let repository = GitRepository(root: "/repo", gitDirectory: "/repo/.git", commonDirectory: "/repo/.git")
    static let branch = GitBranch(reference: "refs/heads/main", oid: String(repeating: "a", count: 40))
    private var current = PushReviewFixture.branch
    private(set) var writes = 0
    private(set) var sent: GitPushPlan?
    private var failure = false, hold = false
    private var continuation: CheckedContinuation<Void, Never>?
    func snapshot(at projectRoot: String) async throws -> GitSnapshot { .init(repository: Self.repository, branch: "main", head: current.oid, changes: [], branches: [current], remotes: ["origin"]) }
    func history(in repository: GitRepository, revision: String, offset: Int, count: Int) async throws -> GitHistoryPage { .init(commits: [], hasMore: false) }
    func files(in repository: GitRepository, commit: GitCommit) async throws -> [GitCommitFile] { [] }
    func diff(in repository: GitRepository, comparison: GitComparison) async throws -> String { "" }
    func planPush(in snapshot: GitSnapshot, branch: GitBranch, remote: String, destination: String) async throws -> GitPushPlan {
        if hold { hold = false; await withCheckedContinuation { continuation = $0 } }

        return .init(repository: Self.repository, branch: branch, remote: remote, destination: destination, url: "https://host/repo.git")
    }
    func perform(_ action: GitLocalAction, expected: GitSnapshot, output: @escaping @Sendable (String) -> Void) async throws {
        guard case .push(let plan) = action else { throw GitInspectionError.failed("Unexpected action") }

        writes += 1; sent = plan; output("Sending reviewed branch\n")
        if failure { failure = false; throw GitInspectionError.failed("Rejected by remote") }
    }
    func holdReview() { hold = true }
    func completeReview() { continuation?.resume(); continuation = nil }
    func waitForReview() async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while continuation == nil, ContinuousClock.now < deadline { await Task.yield() }
        try #require(continuation != nil)
    }
    func failNext() { failure = true }
    func moveBranch() { current = .init(reference: Self.branch.reference, oid: String(repeating: "b", count: 40)) }
}
