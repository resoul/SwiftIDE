import Foundation
import IDEApplication
import Testing
@testable import GitInfrastructure

struct GitRepositoryOperationTests {
    let cli = GitCLI()

    private func fixture() throws -> RepositoryFixture {
        let repo = try RepositoryFixture()
        try repo.write("a", "base\n")
        try repo.git(["add", "."])
        try repo.git(["commit", "-m", "Base"])
        try repo.write("a", "next\n")
        try repo.git(["commit", "-am", "Next"])

        return repo
    }

    private func perform(_ request: GitRepositoryOperationRequest, repo: RepositoryFixture) async throws {
        let snapshot = try await cli.snapshot(at: repo.root)
        let plan = try await cli.planRepositoryOperation(in: snapshot, request: request)
        try await cli.perform(.repositoryOperation(plan), expected: snapshot) { _ in }
    }

    @Test func discardKeepsStagedBytesAndStaleWorktreePlanRefuses() async throws {
        let repo = try fixture()
        defer { repo.remove() }
        try repo.write("a", "staged\n")
        try repo.git(["add", "a"])
        try repo.write("a", "disk\n")
        var snapshot = try await cli.snapshot(at: repo.root)
        let plan = try await cli.planRepositoryOperation(in: snapshot, request: .init(kind: .discard, value: "a"))
        try repo.write("a", "changed after review\n")
        snapshot = try await cli.snapshot(at: repo.root)
        await #expect(throws: GitInspectionError.self) {
            try await cli.perform(.repositoryOperation(plan), expected: snapshot) { _ in }
        }
        #expect(try String(contentsOfFile: repo.root + "/a", encoding: .utf8) == "changed after review\n")
        try await perform(.init(kind: .discard, value: "a"), repo: repo)
        #expect(try String(contentsOfFile: repo.root + "/a", encoding: .utf8) == "staged\n")
        #expect(try repo.git(["show", ":a"]) == Data("staged\n".utf8))
    }

    @Test func threeResetModesPreserveTheirReviewedIndexAndDiskContract() async throws {
        for kind in [GitRepositoryOperationKind.resetSoft, .resetMixed, .resetHard] {
            let repo = try fixture()
            defer { repo.remove() }
            let target = try repo.git(["rev-parse", "HEAD^1"])
            try repo.write("a", "staged\n")
            try repo.git(["add", "a"])
            try repo.write("a", "disk\n")
            try repo.write("keep", "untracked\n")
            try await perform(.init(kind: kind, value: "HEAD^1"), repo: repo)
            #expect(try repo.git(["rev-parse", "HEAD"]) == target)
            #expect(try repo.git(["show", ":a"]) == Data((kind == .resetSoft ? "staged\n" : "base\n").utf8))
            #expect(try String(contentsOfFile: repo.root + "/a", encoding: .utf8) == (kind == .resetHard
                    ? "base\n"
                    : "disk\n"))
            #expect(try String(contentsOfFile: repo.root + "/keep", encoding: .utf8) == "untracked\n")
        }
    }

    @Test func hardResetRefusesUntrackedAndIgnoredOverwrite() async throws {
        for ignored in [false, true] {
            let repo = try fixture()
            defer { repo.remove() }
            try repo.git(["switch", "-c", "target"])
            try repo.write("collision", "target\n")
            try repo.git(["add", "collision"])
            try repo.git(["commit", "-m", "Collision"])
            try repo.git(["switch", "main"])
            try repo.write("collision", "sentinel\n")
            if ignored { try repo.write(".git/info/exclude", "collision\n") }
            await #expect(throws: GitInspectionError.self) {
                try await perform(.init(kind: .resetHard, value: "target"), repo: repo)
            }
            #expect(try String(contentsOfFile: repo.root + "/collision", encoding: .utf8) == "sentinel\n")
        }
    }

    @Test func reviewedCherryPickRevertAndMergeMainlineCreateNativeCommits() async throws {
        let repo = try fixture()
        defer { repo.remove() }
        try repo.git(["branch", "saved"])
        try repo.git(["reset", "--hard", "HEAD^1"])
        try await perform(.init(kind: .cherryPick, value: "saved"), repo: repo)
        #expect(try repo.git(["show", "HEAD:a"]) == Data("next\n".utf8))
        try await perform(.init(kind: .revert, value: "HEAD"), repo: repo)
        #expect(try repo.git(["show", "HEAD:a"]) == Data("base\n".utf8))
        try repo.git(["switch", "-c", "side"])
        try repo.write("side", "side\n")
        try repo.git(["add", "side"])
        try repo.git(["commit", "-m", "Side"])
        try repo.git(["switch", "main"])
        try repo.git(["merge", "--no-ff", "--no-edit", "side"])
        let snapshot = try await cli.snapshot(at: repo.root)
        await #expect(throws: GitInspectionError.self) {
            _ = try await cli.planRepositoryOperation(in: snapshot, request: .init(kind: .revert, value: "HEAD"))
        }
        try await perform(.init(kind: .revert, value: "HEAD", mainline: 1), repo: repo)
        #expect(!FileManager.default.fileExists(atPath: repo.root + "/side"))
    }

    @Test func advancedFetchPrunesOnlyItsRemoteBranchesAndNeverLocalTags() async throws {
        let remote = try fixture(), local = try RepositoryFixture()
        defer {
            remote.remove()
            local.remove()
        }
        try remote.git(["branch", "obsolete"])
        try local.git(["remote", "add", "origin", remote.root])
        try local.git(["fetch", "origin"])
        try local.git(["reset", "--hard", "refs/remotes/origin/main"])
        try local.git(["tag", "local-only"])
        try remote.git(["branch", "-D", "obsolete"])
        try remote.git(["tag", "published"])
        try local.git(["config", "remote.origin.fetch", "+refs/heads/*:refs/heads/*"])
        try await perform(.init(kind: .fetch, value: "origin", tags: true, prune: true), repo: local)
        #expect(try local.git(["show-ref", "--verify", "refs/remotes/origin/obsolete"], accepted: [128]).isEmpty)
        #expect(!(try local.git(["show-ref", "--verify", "refs/tags/local-only"])).isEmpty)
        #expect(!(try local.git(["show-ref", "--verify", "refs/tags/published"])).isEmpty)
        #expect(try local.git(["show-ref", "--verify", "refs/heads/obsolete"], accepted: [128]).isEmpty)
        #expect(try local.git(["rev-parse", "HEAD"]) == remote.git(["rev-parse", "HEAD"]))
    }

    @Test func submoduleUpdateUsesReviewedGitlinkAndRefusesNestedDirtyCheckout() async throws {
        let module = try fixture(), parent = try fixture()
        defer {
            module.remove()
            parent.remove()
        }
        try parent.git(["-c", "protocol.file.allow=always", "submodule", "add", module.root, "module"])
        try parent.git(["commit", "-am", "Module"])
        let first = try module.git(["rev-parse", "HEAD^1"])
        try parent.git([
            "-C",
            "module",
            "checkout",
            String(decoding: first, as: UTF8.self).trimmingCharacters(in: .newlines)
        ])
        try await perform(.init(kind: .updateSubmodule, value: "module"), repo: parent)
        #expect(try parent.git(["-C", "module", "rev-parse", "HEAD"]) == module.git(["rev-parse", "HEAD"]))
        try parent.write("module/a", "nested dirty\n")
        let snapshot = try await cli.snapshot(at: parent.root)
        await #expect(throws: GitInspectionError.self) {
            _ = try await cli.planRepositoryOperation(
                in: snapshot,
                request: .init(kind: .updateSubmodule, value: "module")
            )
        }
        #expect(try String(contentsOfFile: parent.root + "/module/a", encoding: .utf8) == "nested dirty\n")
    }

    @Test func forcePushUsesExactObservedLeaseAndRefusesMovedRemote() async throws {
        let remote = try fixture(), local = try RepositoryFixture(), host = try RepositoryFixture()
        defer {
            remote.remove()
            local.remove()
            host.remove()
        }
        let bare = host.root + "/remote.git"
        try remote.git(["clone", "--bare", remote.root, bare])
        try local.git(["remote", "add", "origin", bare])
        try local.git(["fetch", "origin"])
        try local.git(["reset", "--hard", "refs/remotes/origin/main"])
        try local.git(["reset", "--hard", "HEAD^1"])
        var snapshot = try await cli.snapshot(at: local.root)
        let branch = try #require(snapshot.branches.first { $0.name == "main" })
        let plan = try await cli.planForcePush(in: snapshot, branch: branch, remote: "origin", destination: "main")
        #expect(plan.lease == String(decoding: try remote.git(["rev-parse", "HEAD"]), as: UTF8.self)
            .trimmingCharacters(in: .newlines))
        try await cli.perform(.push(plan), expected: snapshot) { _ in }
        #expect(try host.git(["--git-dir=" + bare, "rev-parse", "refs/heads/main"]) == local.git(["rev-parse", "HEAD"]))
        snapshot = try await cli.snapshot(at: local.root)
        let stale = try await cli.planForcePush(in: snapshot, branch: branch, remote: "origin", destination: "main")
        try remote.git(["push", "--force", bare, "main"])
        await #expect(throws: GitInspectionError.self) {
            try await cli.perform(.push(stale), expected: snapshot) { _ in }
        }
        #expect(try host.git(["--git-dir=" + bare, "rev-parse", "refs/heads/main"]) == remote.git([
            "rev-parse",
            "HEAD"
        ]))
    }
}

extension GitRepositoryOperationTests {
    @Test func submoduleAddDeinitializeReinitializeAndRemoveKeepGitObjectsAndRefuseIgnoredData() async throws {
        let module = try fixture(), parent = try fixture()
        defer {
            module.remove()
            parent.remove()
        }
        try await perform(.init(kind: .addSubmodule, value: "nested/module", url: module.root), repo: parent)
        #expect(try parent.git(["-C", "nested/module", "rev-parse", "HEAD"]) == module.git(["rev-parse", "HEAD"]))
        #expect(try await cli.snapshot(at: parent.root).changes.contains {
            $0.path == ".gitmodules" && !$0.decoration.index.isEmpty
        })
        try parent.git(["commit", "-am", "Module"])
        try parent.write("nested/module/.gitignore", "private-data\n")
        try parent.git(["-C", "nested/module", "add", ".gitignore"])
        try parent.git(["-C", "nested/module", "config", "user.name", "Fixture"])
        try parent.git(["-C", "nested/module", "config", "user.email", "fixture@example.test"])
        try parent.git(["-C", "nested/module", "config", "commit.gpgsign", "false"])
        try parent.git(["-C", "nested/module", "commit", "-m", "Ignore"])
        try parent.git(["add", "nested/module"])
        try parent.git(["commit", "-m", "Updated pointer"])
        try parent.write("nested/module/private-data", "preserve ignored\n")
        for kind in [GitRepositoryOperationKind.deinitSubmodule, .removeSubmodule] {
            await #expect(throws: GitInspectionError.self) {
                try await perform(.init(kind: kind, value: "nested/module"), repo: parent)
            }
        }
        #expect(try String(contentsOfFile: parent.root + "/nested/module/private-data", encoding: .utf8) ==
            "preserve ignored\n")
        try FileManager.default.removeItem(atPath: parent.root + "/nested/module/private-data")
        let pointer = try parent.git(["-C", "nested/module", "rev-parse", "HEAD"])
        try await perform(.init(kind: .deinitSubmodule, value: "nested/module"), repo: parent)
        #expect(!FileManager.default.fileExists(atPath: parent.root + "/nested/module/.git"))
        #expect(FileManager.default.fileExists(atPath: parent.root + "/.git/modules/nested/module"))
        try await perform(.init(kind: .updateSubmodule, value: "nested/module"), repo: parent)
        #expect(try parent.git(["-C", "nested/module", "rev-parse", "HEAD"]) == pointer)
        try await perform(.init(kind: .removeSubmodule, value: "nested/module"), repo: parent)
        #expect(!FileManager.default.fileExists(atPath: parent.root + "/nested/module"))
        #expect(FileManager.default.fileExists(atPath: parent.root + "/.git/modules/nested/module"))
        #expect(try await cli.snapshot(at: parent.root).changes.contains {
            $0.path == "nested/module" && $0.decoration.index == "D"
        })
    }
}
