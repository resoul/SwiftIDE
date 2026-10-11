import Foundation
import Testing
import IDEApplication
@testable import GitInfrastructure

struct GitPullTests {
    @Test func fastForwardFetchesOnlyReviewedHeadAndIgnoresMappingsPushURLAndPullPolicy() async throws {
        let local = try RepositoryFixture(), remote = try RepositoryFixture()
        defer { local.remove(); remote.remove() }
        try remote.write("a", "base"); try remote.git(["add", "."]); try remote.git(["commit", "-m", "Base"])
        let bare = remote.root + "/bare.git"
        try remote.git(["clone", "--bare", remote.root, bare])
        try local.git(["fetch", bare, "main"]); try local.git(["reset", "--hard", "FETCH_HEAD"])
        try local.git(["remote", "add", "origin", bare]); try local.git(["config", "remote.origin.pushurl", remote.root + "/wrong.git"])
        try local.git(["config", "remote.origin.fetch", "+refs/heads/*:refs/heads/*"])
        try local.git(["config", "pull.rebase", "true"]); try local.git(["config", "merge.autostash", "true"])
        try local.git(["config", "fetch.prune", "true"]); try local.git(["config", "fetch.pruneTags", "true"])
        try remote.write("a", "remote"); try remote.git(["commit", "-am", "Remote"])
        try remote.git(["tag", "do-not-fetch"]); try remote.git(["branch", "other"])
        try remote.git(["push", bare, "main", "other", "--tags"])
        try local.write("untracked", "keep")
        let fetchHead = try Data(contentsOf: URL(fileURLWithPath: local.root + "/.git/FETCH_HEAD"))
        let cli = GitCLI(), snapshot = try await cli.snapshot(at: local.root)
        let plan = try await cli.planPull(in: snapshot, remote: "origin", source: "main")
        #expect(plan.url == bare)
        try await cli.perform(.pull(plan), expected: snapshot) { _ in }
        #expect(try local.git(["rev-parse", "HEAD"]) == remote.git(["rev-parse", "HEAD"]))
        #expect(try String(contentsOfFile: local.root + "/a", encoding: .utf8) == "remote")
        #expect(try String(contentsOfFile: local.root + "/untracked", encoding: .utf8) == "keep")
        #expect(try local.git(["show-ref", "--verify", "refs/heads/other"], accepted: [128]).isEmpty)
        #expect(try local.git(["show-ref", "--verify", "refs/remotes/origin/other"], accepted: [128]).isEmpty)
        #expect(try local.git(["show-ref", "--verify", "refs/tags/do-not-fetch"], accepted: [128]).isEmpty)
        #expect(try local.git(["config", "--get", "branch.main.remote"], accepted: [1]).isEmpty)
        #expect(try Data(contentsOf: URL(fileURLWithPath: local.root + "/.git/FETCH_HEAD")) == fetchHead)
        let fresh = try await cli.snapshot(at: local.root)
        let again = try await cli.planPull(in: fresh, remote: "origin", source: "main")
        try await cli.perform(.pull(again), expected: fresh) { _ in } // Already up to date.
        try local.write("a", "local ahead"); try local.git(["commit", "-am", "Local ahead"])
        let ahead = try await cli.snapshot(at: local.root), localHead = try local.git(["rev-parse", "HEAD"])
        try await cli.perform(.pull(try await cli.planPull(in: ahead, remote: "origin", source: "main")), expected: ahead) { _ in }
        #expect(try local.git(["rev-parse", "HEAD"]) == localHead)
    }

    @Test func divergenceDirtyIndexOperationsAndUntrackedOverwriteNeverDiscardLocalData() async throws {
        let local = try RepositoryFixture(), remote = try RepositoryFixture()
        defer { local.remove(); remote.remove() }
        try remote.write("a", "base"); try remote.git(["add", "."]); try remote.git(["commit", "-m", "Base"])
        try local.git(["fetch", remote.root, "main"]); try local.git(["reset", "--hard", "FETCH_HEAD"])
        try local.git(["remote", "add", "origin", remote.root])
        try remote.write("a", "remote"); try remote.write("collision", "remote file"); try remote.git(["add", "."]); try remote.git(["commit", "-m", "Remote"])
        try local.write("a", "local commit"); try local.git(["commit", "-am", "Local"])
        let cli = GitCLI(), before = try local.git(["rev-parse", "HEAD"])
        var snapshot = try await cli.snapshot(at: local.root)
        var plan = try await cli.planPull(in: snapshot, remote: "origin", source: "main")
        await #expect(throws: GitInspectionError.self) { try await cli.perform(.pull(plan), expected: snapshot) { _ in } }
        #expect(try local.git(["rev-parse", "HEAD"]) == before)
        #expect(try String(contentsOfFile: local.root + "/a", encoding: .utf8) == "local commit")
        try local.git(["reset", "--hard", "HEAD~1"])
        for staged in [false, true] {
            try local.write("a", "local edit")
            if staged { try local.git(["add", "a"]) }
            snapshot = try await cli.snapshot(at: local.root); plan = try await cli.planPull(in: snapshot, remote: "origin", source: "main")
            await #expect(throws: GitInspectionError.self) { try await cli.perform(.pull(plan), expected: snapshot) { _ in } }
            #expect(try String(contentsOfFile: local.root + "/a", encoding: .utf8) == "local edit")
            try local.git(["reset", "--hard", "HEAD"])
        }
        try local.write(".git/MERGE_HEAD", String(decoding: before, as: UTF8.self))
        snapshot = try await cli.snapshot(at: local.root); plan = try await cli.planPull(in: snapshot, remote: "origin", source: "main")
        await #expect(throws: GitInspectionError.self) { try await cli.perform(.pull(plan), expected: snapshot) { _ in } }
        try FileManager.default.removeItem(atPath: local.root + "/.git/MERGE_HEAD")
        try local.write("collision", "do not overwrite")
        snapshot = try await cli.snapshot(at: local.root); plan = try await cli.planPull(in: snapshot, remote: "origin", source: "main")
        let cleanHead = try local.git(["rev-parse", "HEAD"])
        await #expect(throws: GitInspectionError.self) { try await cli.perform(.pull(plan), expected: snapshot) { _ in } }
        #expect(try local.git(["rev-parse", "HEAD"]) == cleanHead)
        #expect(try String(contentsOfFile: local.root + "/collision", encoding: .utf8) == "do not overwrite")
        // Git normally overwrites ignored untracked paths during fast-forward; protect those too.
        try local.write(".git/info/exclude", "collision\n")
        snapshot = try await cli.snapshot(at: local.root); plan = try await cli.planPull(in: snapshot, remote: "origin", source: "main")
        await #expect(throws: GitInspectionError.self) { try await cli.perform(.pull(plan), expected: snapshot) { _ in } }
        #expect(try local.git(["rev-parse", "HEAD"]) == cleanHead)
        #expect(try String(contentsOfFile: local.root + "/collision", encoding: .utf8) == "do not overwrite")
    }

    @Test func changedFetchAddressSourceOrDetachedHeadRefusesReviewedPull() async throws {
        let local = try RepositoryFixture(), remote = try RepositoryFixture()
        defer { local.remove(); remote.remove() }
        try local.write("a", "base"); try local.git(["add", "."]); try local.git(["commit", "-m", "Base"])
        try local.git(["remote", "add", "origin", remote.root])
        let cli = GitCLI(), snapshot = try await cli.snapshot(at: local.root)
        let plan = try await cli.planPull(in: snapshot, remote: "origin", source: "main")
        try local.git(["config", "remote.origin.url", remote.root + "/missing"])
        await #expect(throws: GitInspectionError.failed("Fetch address changed since review; review Pull again")) { try await cli.perform(.pull(plan), expected: snapshot) { _ in } }
        try local.git(["config", "remote.origin.url", remote.root])
        for name in ["bad space", "-main", ":main", "../escape"] {
            await #expect(throws: GitInspectionError.self) { try await cli.planPull(in: snapshot, remote: "origin", source: name) }
        }
        try local.git(["config", "--add", "remote.origin.url", remote.root + "/second"])
        await #expect(throws: GitInspectionError.self) { try await cli.planPull(in: snapshot, remote: "origin", source: "main") }
        try local.git(["checkout", "--detach"])
        let detached = try await cli.snapshot(at: local.root)
        await #expect(throws: GitInspectionError.self) { try await cli.planPull(in: detached, remote: "origin", source: "main") }
        await #expect(throws: GitInspectionError.self) { try await cli.perform(.pull(plan), expected: detached) { _ in } }
    }

    @Test func cancellationAfterFastForwardStopsHookChildrenWithoutClaimingRollback() async throws {
        let local = try RepositoryFixture(), remote = try RepositoryFixture()
        defer { local.remove(); remote.remove() }
        try remote.write("a", "base"); try remote.git(["add", "."]); try remote.git(["commit", "-m", "Base"])
        try local.git(["fetch", remote.root, "main"]); try local.git(["reset", "--hard", "FETCH_HEAD"])
        try local.git(["remote", "add", "origin", remote.root])
        try remote.write("a", "remote"); try remote.git(["commit", "-am", "Remote"])
        try local.write(".git/hooks/post-merge", "#!/bin/sh\n/bin/sleep 30 &\necho $! > '\(local.root)/.git/child.pid'\nwait\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: local.root + "/.git/hooks/post-merge")
        let cli = GitCLI(), snapshot = try await cli.snapshot(at: local.root)
        let plan = try await cli.planPull(in: snapshot, remote: "origin", source: "main")
        let task = Task { try await cli.perform(.pull(plan), expected: snapshot) { _ in } }
        let deadline = ContinuousClock.now + .seconds(10)
        while !FileManager.default.fileExists(atPath: local.root + "/.git/child.pid"), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let pid = try #require(Int32(try String(contentsOfFile: local.root + "/.git/child.pid", encoding: .utf8).trimmingCharacters(in: .newlines)))
        await #expect(throws: GitInspectionError.failed("Another Git action is running for this repository")) { try await cli.perform(.pull(plan), expected: snapshot) { _ in } }
        task.cancel(); await #expect(throws: CancellationError.self) { try await task.value }
        let end = ContinuousClock.now + .seconds(2)
        while kill(pid, 0) == 0, ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(10)) }
        #expect(kill(pid, 0) != 0)
        #expect(try local.git(["rev-parse", "HEAD"]) == remote.git(["rev-parse", "HEAD"]))
        #expect(try String(contentsOfFile: local.root + "/a", encoding: .utf8) == "remote")
        try FileManager.default.removeItem(atPath: local.root + "/.git/hooks/post-merge")
        let fresh = try await cli.snapshot(at: local.root)
        try await cli.perform(.pull(try await cli.planPull(in: fresh, remote: "origin", source: "main")), expected: fresh) { _ in }
    }
}
