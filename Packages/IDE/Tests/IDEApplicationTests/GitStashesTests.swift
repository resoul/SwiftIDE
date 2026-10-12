import Foundation
import Testing
@testable import IDEApplication

private actor StashModelService: GitInspecting, GitMutating, GitStashReading {
    var head = String(repeating: "a", count: 40)
    var pending: [CheckedContinuation<GitStashList, Never>] = []
    var reads: Int { pending.count }
    var operations: [GitAction] = []

    func moveHead() { head = String(repeating: "b", count: 40) }

    func snapshot(at projectRoot: String) async throws -> GitSnapshot {
        .init(
            repository: .init(
                root: projectRoot,
                gitDirectory: projectRoot + "/.git",
                commonDirectory: projectRoot + "/.git"
            ),
            branch: "main",
            head: head,
            changes: [],
            mutationToken: head
        )
    }

    func stashes(in repository: GitRepository) async throws -> GitStashList {
        await withCheckedContinuation { pending.append($0) }
    }

    func finish(_ index: Int, token: String) {
        pending[index].resume(returning: .init(entries: [
            .init(selector: "stash@{0}", oid: head, date: .init(timeIntervalSince1970: 1), message: token)
        ], token: token))
    }

    func perform(
        _ action: GitAction,
        expected: GitSnapshot,
        output: @escaping @Sendable (String) -> Void
    ) async throws {
        operations.append(action)
        throw GitInspectionError.failed("fixture failure")
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

    func diff(in repository: GitRepository, comparison: GitComparison) async throws -> String { "stash preview" }
}

@MainActor
struct GitStashesTests {
    private func wait(_ predicate: () async -> Bool) async throws {
        let end = ContinuousClock.now + .seconds(5)
        while !(await predicate()), ContinuousClock.now < end { await Task.yield() }
        try #require(await predicate())
    }

    @Test func replacedAndStoppedReadsCannotPublishLateEntriesOrEnableMutations() async throws {
        let service = StashModelService(), workspace = GitWorkspace(root: "/repo", service: service)
        let model = GitStashes(workspace: workspace)
        defer {
            model.stop()
            workspace.stop()
        }
        workspace.refresh()
        try await wait { await service.reads == 1 }
        model.refresh()
        try await wait { await service.reads == 2 }
        await service.finish(1, token: "new")
        try await wait { model.canReview }
        let entry = try #require(model.list?.entries.first)
        model.review(.drop(entry))
        #expect(model.canStart)
        await service.finish(0, token: "old")
        for _ in 0..<10 { await Task.yield() }
        #expect(model.plan?.listToken == "new" && model.list?.token == "new")
        model.refresh()
        try await wait { await service.reads == 3 }
        model.stop()
        await service.finish(2, token: "closed")
        for _ in 0..<10 { await Task.yield() }
        #expect(model.plan == nil && !model.canStart && model.list?.token == "new")
    }

    @Test func editsBadInputAndCheckoutRefreshRequireANewReview() async throws {
        let service = StashModelService(), workspace = GitWorkspace(root: "/repo", service: service)
        let model = GitStashes(workspace: workspace)
        defer {
            model.stop()
            workspace.stop()
        }
        workspace.refresh()
        try await wait { await service.reads == 1 }
        await service.finish(0, token: "first")
        try await wait { model.canReview }
        model.review(.create(message: "bad\0input", inclusion: .tracked))
        #expect(model.reviewError != nil && !model.canStart && model.canReview)
        model.invalidate()
        model.review(.create(message: "valid", inclusion: .ignored))
        #expect(model.reviewError == nil && model.canStart)
        model.invalidate()
        #expect(!model.canStart)
        let entry = try #require(model.list?.entries.first)
        model.review(.pop(entry, restoreIndex: true))
        #expect(model.canStart)
        await service.moveHead()
        workspace.refresh()
        #expect(!model.canStart)
        try await wait { await service.reads == 2 }
        await service.finish(1, token: "second")
        try await wait { model.canReview }
        #expect(model.plan == nil && model.list?.token == "second")
    }

    @Test func stashCheckoutReconcilesOnceAndUnlocksAfterFailureWhileDropDoesNotTouchEditors() async throws {
        let service = StashModelService(), workspace = GitWorkspace(root: "/repo", service: service)
        defer { workspace.stop() }
        workspace.refresh()
        try await wait { workspace.canMutate }
        let snapshot = try #require(workspace.snapshot)
        let entry = GitStashEntry(selector: "stash@{0}", oid: try #require(snapshot.head), date: .now, message: "saved")
        let plan = GitStashPlan(
            repository: snapshot.repository,
            head: entry.oid,
            branch: snapshot.branch,
            listToken: "first",
            request: .pop(entry, restoreIndex: false)
        )
        var prepared = 0, finished = 0
        workspace.prepareCheckout = { _ in
            prepared += 1

            return false
        }
        workspace.checkoutFinished = { _ in finished += 1 }
        workspace.perform(.stash(plan))
        try await wait { workspace.canMutate && workspace.operationState == .cancelled }
        let cancelledOperations = await service.operations
        #expect(prepared == 1 && finished == 0 && cancelledOperations.isEmpty)
        workspace.prepareCheckout = { _ in
            prepared += 1

            return true
        }
        workspace.perform(.stash(plan))
        try await wait { workspace.canMutate && finished == 1 }
        let failedOperations = await service.operations
        #expect(prepared == 2 && failedOperations.count == 1)
        let drop = GitStashPlan(
            repository: snapshot.repository,
            head: entry.oid,
            branch: snapshot.branch,
            listToken: "first",
            request: .drop(entry)
        )
        workspace.perform(.stash(drop))
        try await wait {
            let count = await service.operations.count

            return workspace.canMutate && count == 2
        }
        #expect(prepared == 2 && finished == 1)
    }
}
