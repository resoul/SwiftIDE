import Foundation
import IDEApplication
import Testing
@testable import GitInfrastructure

struct GitManagementTests {
    let cli = GitCLI()

    private func fixture() throws -> RepositoryFixture {
        let repo = try RepositoryFixture()
        try repo.write("a.txt", "base\n")
        try repo.git(["add", "."])
        try repo.git(["commit", "-m", "Base"])

        return repo
    }

    private func perform(_ request: GitManagementRequest, repo: RepositoryFixture) async throws {
        let snapshot = try await cli.snapshot(at: repo.root)
        let plan = try await cli.planManagement(in: snapshot, request: request)
        try await cli.perform(.manage(plan), expected: snapshot, output: { _ in })
    }

    @Test func localManagementPreservesDirtyDiskAndIndexAndTagAnnotations() async throws {
        let repo = try fixture()
        defer { repo.remove() }
        try repo.write("a.txt", "staged\n")
        try repo.git(["add", "a.txt"])
        try repo.write("a.txt", "unsaved disk\n")
        let index = try repo.git(["diff", "--cached"]), disk = try repo.git(["diff"])
        try await perform(.init(kind: .renameBranch, name: "main", value: "renamed"), repo: repo)
        #expect(try await cli.snapshot(at: repo.root).branch == "renamed")
        try await perform(.init(kind: .addRemote, name: "new/origin", value: repo.root), repo: repo)
        try await perform(.init(kind: .editRemote, name: "new/origin", value: repo.root + "/other"), repo: repo)
        try await perform(.init(kind: .removeRemote, name: "new/origin"), repo: repo)
        try await perform(.init(kind: .createTag, name: "release/v1", message: "Release\n\nAnnotation"), repo: repo)
        let snapshot = try await cli.snapshot(at: repo.root)
        #expect(snapshot.tags.first?.name == "release/v1" && snapshot.tags.first?.commit == snapshot.head)
        #expect(String(decoding: try repo.git(["cat-file", "tag", "release/v1"]), as: UTF8.self).contains("Annotation"))
        try await perform(.init(kind: .deleteTag, name: "release/v1"), repo: repo)
        #expect(try await cli.snapshot(at: repo.root).tags.isEmpty)
        #expect(try repo.git(["diff", "--cached"]) == index && repo.git(["diff"]) == disk)
    }

    @Test func branchDeletionRequiresExplicitUnmergedChoiceAndRefusesWorktreeOwners() async throws {
        let repo = try fixture()
        defer { repo.remove() }
        try repo.git(["switch", "-c", "topic"])
        try repo.write("topic.txt", "topic")
        try repo.git(["add", "."])
        try repo.git(["commit", "-m", "Unmerged"])
        try repo.git(["switch", "main"])
        await #expect(throws: GitInspectionError.self) {
            try await perform(.init(kind: .deleteBranch, name: "topic"), repo: repo)
        }
        let linked = repo.root + "-linked"
        defer { try? FileManager.default.removeItem(atPath: linked) }
        try repo.git(["worktree", "add", linked, "topic"])
        await #expect(throws: GitInspectionError.self) {
            try await perform(.init(kind: .deleteBranch, name: "topic", allowUnmerged: true), repo: repo)
        }
        try repo.git(["worktree", "remove", linked])
        try repo.git(["config", "branch.topic.remote", "origin"])
        try await perform(.init(kind: .deleteBranch, name: "topic", allowUnmerged: true), repo: repo)
        #expect(try await cli.snapshot(at: repo.root).branches.allSatisfy { $0.name != "topic" })
        #expect(try repo.git(["config", "--get", "branch.topic.remote"], accepted: [1]).isEmpty)
        await #expect(throws: GitInspectionError.self) {
            try await perform(.init(kind: .deleteBranch, name: "main", allowUnmerged: true), repo: repo)
        }
    }

    @Test func changedRefsConfigurationAndInvalidNamesCannotApplyReviewedManagement() async throws {
        let repo = try fixture()
        defer { repo.remove() }
        let snapshot = try await cli.snapshot(at: repo.root)
        let plan = try await cli.planManagement(in: snapshot, request: .init(kind: .createTag, name: "v1"))
        try repo.git(["config", "some.setting", "changed"])
        await #expect(throws: GitInspectionError.self) {
            try await cli.perform(.manage(plan), expected: snapshot, output: { _ in })
        }
        await #expect(throws: GitInspectionError.self) {
            try await perform(.init(kind: .createTag, name: "bad name"), repo: repo)
        }
        await #expect(throws: GitInspectionError.self) {
            try await perform(.init(kind: .addRemote, name: "origin", value: "ext::bad"), repo: repo)
        }
        await #expect(throws: GitInspectionError.self) {
            try await perform(
                .init(kind: .addRemote, name: "origin", value: "https://user:secret@example.test/repo"),
                repo: repo
            )
        }
        try await perform(.init(kind: .createTag, name: "v1"), repo: repo)
        await #expect(throws: GitInspectionError.self) {
            try await perform(.init(kind: .createTag, name: "v1"), repo: repo)
        }
    }

    @Test func remoteDeletionIsSeparateAndRefusesAChangedRemoteObject() async throws {
        let repo = try fixture(), server = try RepositoryFixture()
        defer {
            repo.remove()
            server.remove()
        }
        try server.git(["config", "receive.denyCurrentBranch", "ignore"])
        try repo.git(["remote", "add", "origin", server.root])
        try repo.git(["push", "origin", "HEAD:refs/heads/topic"])
        try repo.git(["tag", "v1"])
        try repo.git(["push", "origin", "refs/tags/v1"])
        let snapshot = try await cli.snapshot(at: repo.root)
        let plan = try await cli.planManagement(
            in: snapshot,
            request: .init(kind: .deleteRemoteBranch, name: "origin", value: "topic")
        )
        try repo.git(["commit", "--allow-empty", "-m", "Moved remote"])
        try repo.git(["push", "origin", "HEAD:refs/heads/topic"])
        let current = try await cli.snapshot(at: repo.root)
        await #expect(throws: GitInspectionError.self) {
            try await cli.perform(.manage(plan), expected: current, output: { _ in })
        }
        try await perform(.init(kind: .deleteRemoteBranch, name: "origin", value: "topic"), repo: repo)
        try await perform(.init(kind: .deleteRemoteTag, name: "origin", value: "v1"), repo: repo)
        #expect(try server.git(["show-ref", "--verify", "refs/heads/topic"], accepted: [128, 1]).isEmpty)
        #expect(try server.git(["show-ref", "--verify", "refs/tags/v1"], accepted: [128, 1]).isEmpty)
        #expect(try repo.git(["show-ref", "--verify", "refs/tags/v1"]).isEmpty == false)
    }

    @Test func allReferenceHistoryIncludesUnmergedTipsAndKeepsPageOrderingStable() async throws {
        let repo = try fixture()
        defer { repo.remove() }
        try repo.git(["switch", "-c", "side"])
        try repo.write("side.txt", "side")
        try repo.git(["add", "."])
        try repo.git(["commit", "-m", "Side"])
        try repo.git(["switch", "main"])
        try repo.write("main.txt", "main")
        try repo.git(["add", "."])
        try repo.git(["commit", "-m", "Main"])
        var snapshot = try await cli.snapshot(at: repo.root)
        let page = try await cli.history(
            in: snapshot.repository,
            tips: snapshot.branches.map(\.oid),
            offset: 0,
            count: 1
        )
        let rest = try await cli.history(
            in: snapshot.repository,
            tips: snapshot.branches.map(\.oid),
            offset: 1,
            count: 100
        )
        #expect(page.hasMore && Set((page.commits + rest.commits).map(\.subject)) == ["Base", "Side", "Main"])
        try repo.git(["merge", "--no-ff", "side", "-m", "Merge"])
        snapshot = try await cli.snapshot(at: repo.root)
        let history = try await cli.history(in: snapshot.repository, revision: snapshot.head!, offset: 0, count: 100)
        #expect(history.commits.first?.parents.count == 2)
        for (index, commit) in history.commits.enumerated() {
            for parent in commit.parents {
                #expect(history.commits.firstIndex { $0.oid == parent }.map { $0 > index } == true)
            }
        }
    }
}
