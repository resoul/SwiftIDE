import Foundation
import Testing
import IDETestSupport
@testable import IDEApplication

@Suite(.serialized) @MainActor
struct GitLocalActionsTests {
    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        try #require(predicate())
    }

    @Test func busyActionIgnoresDuplicatesDefersRefreshAndCancellationKeepsGateUntilExit() async throws {
        let service = LocalActionFixture(), model = GitWorkspace(root: "/repo", service: service)
        defer { model.stop() }
        model.refresh()
        try await wait { model.state == .ready }
        let change = try #require(model.snapshot?.changes.first)
        model.perform(.stage(change))
        try await wait { model.operationOutput.contains("started") }
        model.perform(.stage(change))
        model.refresh()
        let calls = await service.calls, snapshots = await service.snapshots
        #expect(calls == 1 && snapshots == 1)
        model.cancelOperation()
        #expect(model.operationState == .cancelling && !model.canMutate)
        await service.complete()
        try await wait { model.operationState == .cancelled && model.state == .ready }
        #expect(await service.snapshots == 2)
        model.perform(.stage(change))
        try await wait { model.operationState == .running }
        try await service.waitForCall(2)
        await service.complete()
        try await wait { model.operationState == .succeeded && model.state == .ready }
    }

    @Test func checkoutNeedsDocumentReconciliationAndRejectsHeadMovingDuringIt() async throws {
        let service = LocalActionFixture(), model = GitWorkspace(root: "/repo", service: service)
        defer { model.stop() }
        model.refresh()
        try await wait { model.state == .ready }
        let branch = try #require(model.snapshot?.branches.first)
        model.perform(.switchBranch(branch))
        try await wait { model.operationState == .cancelled && model.state == .ready }
        #expect(await service.calls == 0)
        var unlocked = 0
        model.prepareCheckout = { _ in
            await service.moveHead()

            return true
        }
        model.checkoutFinished = { _ in unlocked += 1 }
        model.perform(.switchBranch(branch))
        try await wait {
            if case .failed = model.operationState { return model.state == .ready }

            return false
        }
        #expect(await service.calls == 0)
        #expect(unlocked == 1)
        model.prepareCheckout = { _ in true }
        model.perform(.switchBranch(branch))
        try await service.waitForCall(1)
        model.stop()
        await service.complete()
        try await wait { unlocked == 2 }
        #expect(model.operationState == .running, "stopped model cannot publish a late result")
    }

    @Test func compositionAndFailedSaveBlockCheckoutWithoutDroppingText() async throws {
        let backend = StringDocumentBackend(loadedText: "base")
        let document = DocumentSession(path: "/repo/a", backend: backend)
        try document.replaceText("unsaved", expectedVersion: 0)
        var prompts = 0
        let coordinator = GitCheckoutDocuments(documents: { [document] }, prompt: { _ in prompts += 1

            return .save
        }, save: { _ in
            false
        })
        backend.simulateComposition(.began)
        #expect(await coordinator.prepare(root: "/repo") == false && prompts == 0)
        backend.simulateComposition(.ended)
        #expect(await coordinator.prepare(root: "/repo") == false && prompts == 1)
        #expect(document.text == "unsaved" && document.isDirty)
    }

    @Test func saveOrCancelCoversAllRepositoryDocumentsAndRechecksTypingDuringSave() async throws {
        let a = DocumentSession(path: "/repo/a", backend: StringDocumentBackend(loadedText: "base"))
        let b = DocumentSession(path: "/repo/other/b", backend: StringDocumentBackend(loadedText: "base"))
        let outside = DocumentSession(path: "/repo-other/c", backend: StringDocumentBackend(loadedText: "base"))
        for document in [a, b, outside] { try document.replaceText("edited", expectedVersion: 0) }
        let save = SaveDocumentUseCase(store: MemoryDocumentFileStore())
        var asked: [String] = []
        let cancelled = GitCheckoutDocuments(
            documents: { [a, b, outside] },
            prompt: { document in asked.append(document.path)

                return .cancel
            },
            save: { _ in
                Issue.record("Cancel must not save")

                return false
            }
        )
        #expect(await cancelled.prepare(root: "/repo") == false)
        #expect(a.isDirty && b.isDirty && asked == ["/repo/a"])
        asked = []
        let approved = GitCheckoutDocuments(
            documents: { [a, b, outside] },
            prompt: { document in asked.append(document.path)

                return .save
            },
            save: { document in
                _ = try? await save.execute(document: document)

                return !document.isDirty
            }
        )
        #expect(await approved.prepare(root: "/repo"))
        #expect(asked == ["/repo/a", "/repo/other/b"] && !a.isDirty && !b.isDirty && outside.isDirty)
        try b.replaceText("new edit", expectedVersion: b.version)
        let typed = GitCheckoutDocuments(documents: { [a, b] }, prompt: { _ in .save }, save: { document in
            _ = try? await save.execute(document: document)
            try? a.replaceText("typed in other window", expectedVersion: a.version)

            return true
        })
        #expect(await typed.prepare(root: "/repo") == false)
        #expect(a.isDirty && a.text == "typed in other window")
    }
}

private actor LocalActionFixture: GitInspecting, GitMutating {
    private(set) var calls = 0, snapshots = 0
    private var head = String(repeating: "a", count: 40)
    private var pending: CheckedContinuation<Void, Never>?

    func snapshot(at projectRoot: String) async throws -> GitSnapshot {
        snapshots += 1

        return .init(
            repository: .init(root: "/repo", gitDirectory: "/repo/.git", commonDirectory: "/repo/.git"),
            branch: "main",
            head: head,
            changes: [.init(path: "a", decoration: .init(worktree: "M"))],
            branches: [.init(reference: "refs/heads/other", oid: String(repeating: "b", count: 40))]
        )
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

    func diff(in repository: GitRepository, comparison: GitComparison) async throws -> String { "diff" }

    func perform(
        _ action: GitLocalAction,
        expected: GitSnapshot,
        output: @escaping @Sendable (String) -> Void
    ) async throws {
        calls += 1
        output("started\n")
        await withCheckedContinuation { pending = $0 }
        try Task.checkCancellation()
    }

    func complete() {
        pending?.resume()
        pending = nil
    }

    func moveHead() { head = String(repeating: "c", count: 40) }

    func waitForCall(_ count: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while calls < count, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        try #require(calls >= count)
    }
}
