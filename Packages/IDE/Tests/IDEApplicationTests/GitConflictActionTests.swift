import Foundation
import Testing
@testable import IDEApplication

@Suite(.serialized) @MainActor
struct GitConflictActionTests {
    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        try #require(predicate())
    }

    @Test func allIntegrationAndResolutionWritesUsePreparationAndSaveCancellationPreventsMutation() async throws {
        let fixture = ConflictActionFixture(), workspace = GitWorkspace(root: "/repo", service: fixture)
        defer { workspace.stop() }
        workspace.refresh()
        try await wait { workspace.canMutate }
        let status = GitIntegrationStatus(
            kind: .merge,
            token: "active",
            originalHead: ConflictActionFixture.oid,
            detail: "Merge"
        )
        let data = GitConflict(
            repository: ConflictActionFixture.repository,
            path: "a",
            sides: [],
            indexToken: "index",
            workingToken: "disk",
            workingText: "text",
            workingExists: true
        )
        let target = GitBranch(reference: "refs/heads/incoming", oid: ConflictActionFixture.oid)
        let actions: [GitAction] = [
            .integrate(.init(
                repository: ConflictActionFixture.repository,
                kind: .merge,
                head: ConflictActionFixture.oid,
                branch: "main",
                target: target
            )),
            .continueIntegration(status, "message"),
            .abortIntegration(status),
            .skipRebase(status),
            .resolveConflict(data, .workingFile)
        ]
        workspace.prepareCheckout = { _ in false }
        for action in actions {
            #expect(action.changesCheckout)
            workspace.perform(action)
            try await wait { workspace.operationState == .cancelled && workspace.canMutate }
        }
        #expect(await fixture.calls == 0)
        var finished = 0
        workspace.prepareCheckout = { _ in true }
        workspace.checkoutFinished = { _ in finished += 1 }
        workspace.perform(.continueIntegration(status, "message"))
        try await wait {
            workspace.operationState == .succeeded && workspace.canMutate
        }
        #expect(await fixture.calls == 1 && finished == 1)
    }
}

private actor ConflictActionFixture: GitInspecting, GitMutating {
    static let oid = String(repeating: "a", count: 40)
    static let repository = GitRepository(root: "/repo", gitDirectory: "/repo/.git", commonDirectory: "/repo/.git")
    private(set) var calls = 0

    func snapshot(at projectRoot: String) async throws -> GitSnapshot {
        .init(repository: Self.repository, branch: "main", head: Self.oid, changes: [])
    }

    func history(
        in repository: GitRepository,
        revision: String,
        offset: Int,
        count: Int
    ) async throws -> GitHistoryPage {
        .init(commits: [], hasMore: false)
    }

    func files(in repository: GitRepository, commit: GitCommit) async throws -> [GitCommitFile] { [] }

    func diff(in repository: GitRepository, comparison: GitComparison) async throws -> String { "" }

    func perform(
        _ action: GitAction,
        expected: GitSnapshot,
        output: @escaping @Sendable (String) -> Void
    ) async throws {
        calls += 1
    }
}
