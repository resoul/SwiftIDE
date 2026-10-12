import Foundation
import IDEApplication
import Testing
@testable import GitInfrastructure

struct GitInteractiveRebaseTests {
    private let cli = GitCLI()

    private func fixture() throws -> RepositoryFixture {
        let repo = try RepositoryFixture()
        try repo.write("base", "base\n")
        try repo.git(["add", "."])
        try repo.git(["commit", "-m", "Base"])
        try repo.git(["branch", "onto"])
        for name in ["one", "two", "three"] {
            try repo.write(name, name + "\n")
            try repo.git(["add", name])
            try repo.git(["commit", "-m", name.capitalized])
        }

        return repo
    }

    private func plan(_ repo: RepositoryFixture) async throws -> GitInteractiveRebasePlan {
        let snapshot = try await cli.snapshot(at: repo.root)

        return try await cli.planInteractiveRebase(
            in: snapshot,
            target: #require(snapshot.branches.first { $0.name == "onto" })
        )
    }

    @Test func reorderSquashFixupAndDropUseOnlyReviewedCommits() async throws {
        for action in [GitReplayAction.pick, .squash, .fixup, .drop] {
            let repo = try fixture()
            defer { repo.remove() }
            var value = try await plan(repo)
            #expect(value.commits.map(\.subject) == ["One", "Two", "Three"])
            value.steps.swapAt(0, 1)
            value.steps[1].action = action
            let snapshot = try await cli.snapshot(at: repo.root)
            try await cli.perform(.interactiveRebase(value), expected: snapshot) { _ in }
            let subjects = String(
                decoding: try repo.git(["log", "--format=%s", "--reverse", "onto..HEAD"]),
                as: UTF8.self
            )
            .split(separator: "\n").map(String.init)
            #expect(subjects == (action == .pick ? ["Two", "One", "Three"] : ["Two", "Three"]))
            #expect(try await cli.snapshot(at: repo.root).integration == nil)
            if action == .drop {
                #expect(!FileManager.default.fileExists(atPath: repo.root + "/one"))
            } else {
                #expect(try String(contentsOfFile: repo.root + "/one", encoding: .utf8) == "one\n")
            }

            let message = String(decoding: try repo.git(["log", "--format=%B", "onto..HEAD"]), as: UTF8.self)
            #expect(action == .fixup || action == .drop ? !message.contains("One") : message.contains("One"))
        }
    }

    @Test func editStopsAndContinuesWithStagedAmendment() async throws {
        let repo = try fixture()
        defer { repo.remove() }
        var value = try await plan(repo)
        value.steps[0].action = .edit
        let before = try await cli.snapshot(at: repo.root)
        try await cli.perform(.interactiveRebase(value), expected: before) { _ in }
        var snapshot = try await cli.snapshot(at: repo.root)
        let status = try #require(snapshot.integration)
        #expect(status.isEditingCommit)
        try repo.write("one", "edited\n")
        try repo.git(["add", "one"])
        snapshot = try await cli.snapshot(at: repo.root)
        try await cli.perform(.continueIntegration(status, ""), expected: snapshot) { _ in }
        #expect(try await cli.snapshot(at: repo.root).integration == nil)
        #expect(try repo.git(["show", "HEAD:one"]) == Data("edited\n".utf8))
    }

    @Test func stalePlanMissingCommitDuplicateAndLeadingSquashRefuse() async throws {
        let repo = try fixture()
        defer { repo.remove() }
        let reviewed = try await plan(repo)
        for kind in 0..<3 {
            var value = reviewed
            if kind == 0 { value.steps.removeLast() }
            if kind == 1 { value.steps[1] = value.steps[0] }
            if kind == 2 { value.steps[0].action = .squash }
            #expect(value.validation != nil)
            let snapshot = try await cli.snapshot(at: repo.root)
            await #expect(throws: GitInspectionError.self) {
                try await cli.perform(.interactiveRebase(value), expected: snapshot) { _ in }
            }
        }
        try repo.git(["commit", "--allow-empty", "-m", "Moved"])
        let moved = try await cli.snapshot(at: repo.root)
        await #expect(throws: GitInspectionError.self) {
            try await cli.perform(.interactiveRebase(reviewed), expected: moved) { _ in }
        }
        #expect(try await cli.snapshot(at: repo.root).integration == nil)
    }

    @Test func emptyReplayIsKeptExplicitlyAndMarkerIsCleanedUp() async throws {
        let repo = try RepositoryFixture()
        defer { repo.remove() }
        try repo.write("a", "base\n")
        try repo.git(["add", "."])
        try repo.git(["commit", "-m", "Base"])
        try repo.git(["switch", "-c", "onto"])
        try repo.write("a", "same\n")
        try repo.git(["commit", "-am", "Incoming"])
        try repo.git(["switch", "main"])
        try repo.write("a", "same\n")
        try repo.git(["commit", "-am", "Local keep me"])
        let snapshot = try await cli.snapshot(at: repo.root)
        let target = try #require(snapshot.branches.first { $0.name == "onto" })
        let plan = GitIntegrationPlan(
            repository: snapshot.repository,
            kind: .rebase,
            head: try #require(snapshot.head),
            branch: "main",
            target: target
        )
        await #expect(throws: GitInspectionError.self) {
            try await cli.perform(.integrate(plan), expected: snapshot) { _ in }
        }
        let stopped = try await cli.snapshot(at: repo.root), status = try #require(stopped.integration)
        #expect(stopped.changes.isEmpty && status.stoppedCommit != nil)
        await #expect(throws: GitInspectionError.self) {
            try await cli.perform(.continueIntegration(status, ""), expected: stopped) { _ in }
        }
        try await cli.perform(.keepEmptyRebase(status), expected: stopped) { _ in }
        #expect(try await cli.snapshot(at: repo.root).integration == nil)
        #expect(!FileManager.default.fileExists(atPath: repo.root + "/.git/swiftide-kept-empty"))
        #expect(String(decoding: try repo.git(["log", "-1", "--format=%s"]), as: UTF8.self) == "Local keep me\n")
        #expect(try repo.git(["rev-parse", "HEAD^{tree}"]) == repo.git(["rev-parse", "HEAD^1^{tree}"]))
    }

    @Test func topologyPreservingRebaseRecreatesTwoParentMerge() async throws {
        let repo = try fixture()
        defer { repo.remove() }
        try repo.git(["switch", "-c", "side", "onto"])
        try repo.write("side", "side\n")
        try repo.git(["add", "side"])
        try repo.git(["commit", "-m", "Side"])
        try repo.git(["switch", "main"])
        try repo.git(["merge", "--no-ff", "--no-edit", "side"])
        try repo.git(["switch", "onto"])
        try repo.write("incoming", "incoming\n")
        try repo.git(["add", "incoming"])
        try repo.git(["commit", "-m", "Incoming"])
        try repo.git(["switch", "main"])
        let snapshot = try await cli.snapshot(at: repo.root), target = try #require(snapshot.branches.first {
            $0.name == "onto"
        })
        let plan = GitIntegrationPlan(
            repository: snapshot.repository,
            kind: .rebase,
            head: try #require(snapshot.head),
            branch: "main",
            target: target,
            preserveMerges: true
        )
        await #expect(throws: GitInspectionError.self) { _ = try await self.plan(repo) }
        try await cli.perform(.integrate(plan), expected: snapshot) { _ in }
        #expect(
            String(decoding: try repo.git(["rev-list", "--count", "--min-parents=2", "onto..HEAD"]), as: UTF8.self) ==
                "1\n"
        )
        #expect(try repo.git(["show", "HEAD:side"]) == Data("side\n".utf8))
        #expect(try repo.git(["show", "HEAD:incoming"]) == Data("incoming\n".utf8))
        #expect(try await cli.snapshot(at: repo.root).integration == nil)
    }
}

private final class EmptyReplayCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, any Error>?

    func set(_ task: Task<Void, any Error>) { lock.withLock { self.task = task } }

    func signal(_ text: String) {
        if text.contains("EMPTY_COMMIT_WRITTEN") { lock.withLock { task?.cancel() } }
    }
}

extension GitInteractiveRebaseTests {
    @Test func cancellingAfterEmptyCommitPreventsDuplicateKeepAndAllowsVerifiedContinue() async throws {
        let repo = try RepositoryFixture()
        defer { repo.remove() }
        try repo.write("a", "base\n")
        try repo.git(["add", "."])
        try repo.git(["commit", "-m", "Base"])
        try repo.git(["switch", "-c", "onto"])
        try repo.write("a", "same\n")
        try repo.git(["commit", "-am", "Incoming"])
        try repo.git(["switch", "main"])
        try repo.write("a", "same\n")
        try repo.git(["commit", "-am", "Preserve empty"])
        let snapshot = try await cli.snapshot(at: repo.root), target = try #require(snapshot.branches.first {
            $0.name == "onto"
        })
        let plan = GitIntegrationPlan(
            repository: snapshot.repository,
            kind: .rebase,
            head: try #require(snapshot.head),
            branch: "main",
            target: target
        )
        await #expect(throws: GitInspectionError.self) {
            try await cli.perform(.integrate(plan), expected: snapshot) { _ in }
        }
        let stopped = try await cli.snapshot(at: repo.root), operation = try #require(stopped.integration)
        try repo.write(".git/hooks/post-commit", "#!/bin/sh\necho EMPTY_COMMIT_WRITTEN\n/bin/sleep 20\n")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: repo.root + "/.git/hooks/post-commit"
        )
        let cancellation = EmptyReplayCancellation()
        let task = Task {
            try await cli.perform(.keepEmptyRebase(operation), expected: stopped) { cancellation.signal($0) }
        }
        cancellation.set(task)
        await #expect(throws: CancellationError.self) { try await task.value }
        try FileManager.default.removeItem(atPath: repo.root + "/.git/hooks/post-commit")
        let after = try await cli.snapshot(at: repo.root), pending = try #require(after.integration)
        #expect(pending.emptyAttemptParent == stopped.head && after.head != stopped.head)
        await #expect(throws: GitInspectionError.self) {
            try await cli.perform(.keepEmptyRebase(pending), expected: after) { _ in }
        }
        try await cli.perform(.continueIntegration(pending, ""), expected: after) { _ in }
        #expect(try await cli.snapshot(at: repo.root).integration == nil)
        #expect(String(decoding: try repo.git(["rev-list", "--count", "onto..HEAD"]), as: UTF8.self) == "1\n")
        #expect(!FileManager.default.fileExists(atPath: repo.root + "/.git/swiftide-kept-empty"))
    }
}
