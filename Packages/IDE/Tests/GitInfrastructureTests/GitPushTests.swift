import Foundation
import Testing
import IDEApplication
@testable import GitInfrastructure

struct GitPushTests {
    @Test func pushUsesReviewedPushURLCommitAndOnlyOneDestinationDespiteConfiguredMappings() async throws {
        let repo = try RepositoryFixture(), host = try RepositoryFixture()
        defer {
            repo.remove()
            host.remove()
        }
        try repo.write("a", "base")
        try repo.git(["add", "."])
        try repo.git(["commit", "-m", "Base"])
        let fetchURL = host.root + "/fetch.git", pushURL = host.root + "/push.git"
        try repo.git(["clone", "--bare", repo.root, fetchURL])
        try repo.git(["clone", "--bare", repo.root, pushURL])
        try repo.git(["remote", "add", "origin", fetchURL])
        try repo.git(["config", "remote.origin.pushurl", pushURL])
        try repo.git(["config", "remote.origin.mirror", "true"])
        try repo.git(["config", "remote.origin.push", "+refs/heads/*:refs/heads/*"])
        try repo.git(["config", "push.default", "matching"])
        try repo.git(["config", "push.followTags", "true"])
        try repo.git(["config", "push.autoSetupRemote", "true"])
        try repo.write("a", "committed")
        try repo.git(["commit", "-am", "Local"])
        try repo.git(["tag", "must-not-send"])
        try repo.git(["branch", "must-not-send"])
        try repo.write("a", "staged")
        try repo.git(["add", "a"])
        try repo.write("a", "dirty")
        let cli = GitCLI(), snapshot = try await cli.snapshot(at: repo.root)
        let source = try #require(snapshot.branches.first { $0.name == "main" })
        let plan = try await cli.planPush(in: snapshot, branch: source, remote: "origin", destination: "reviewed/new")
        #expect(plan.url == pushURL)
        // A hook moving the source ref cannot change the commit sent after review.
        try repo.write(".git/hooks/pre-push", "#!/bin/sh\ngit update-ref refs/heads/main HEAD~1\n")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: repo.root + "/.git/hooks/pre-push"
        )
        try await cli.perform(.push(plan), expected: snapshot) { _ in }
        let pushed = String(
            decoding: try host.git(["-C", pushURL, "rev-parse", "refs/heads/reviewed/new"]),
            as: UTF8.self
        ).trimmingCharacters(in: .newlines)
        #expect(pushed == source.oid)
        #expect(try host.git(["-C", pushURL, "show", "refs/heads/reviewed/new:a"]) == Data("committed".utf8))
        #expect(try String(contentsOfFile: repo.root + "/a", encoding: .utf8) == "dirty")
        #expect(try repo.git(["show", ":a"]) == Data("staged".utf8))
        for url in [fetchURL, pushURL] {
            #expect(try host.git(["-C", url, "show-ref", "--verify", "refs/tags/must-not-send"], accepted: [128])
                .isEmpty)
            #expect(try host.git(["-C", url, "show-ref", "--verify", "refs/heads/must-not-send"], accepted: [128])
                .isEmpty)
        }
        #expect(try repo.git(["config", "--get", "branch.main.remote"], accepted: [1]).isEmpty)
    }

    @Test func nonFastForwardAndServerHookRefuseWithoutChangingRemote() async throws {
        let repo = try RepositoryFixture(), host = try RepositoryFixture()
        defer {
            repo.remove()
            host.remove()
        }
        try repo.write("a", "base")
        try repo.git(["add", "."])
        try repo.git(["commit", "-m", "Base"])
        let bare = host.root + "/remote.git"
        try repo.git(["clone", "--bare", repo.root, bare])
        try repo.git(["remote", "add", "origin", bare])
        try repo.write("a", "remote")
        try repo.git(["commit", "-am", "Remote"])
        try repo.git(["push", "origin", "main"])
        let remoteHead = try host.git(["-C", bare, "rev-parse", "HEAD"])
        try repo.git(["reset", "--hard", "HEAD~1"])
        try repo.write("a", "diverged")
        try repo.git(["commit", "-am", "Local"])
        let cli = GitCLI(), snapshot = try await cli.snapshot(at: repo.root),
            source = try #require(snapshot.branches.first {
                $0.name == "main"
            })
        let plan = try await cli.planPush(in: snapshot, branch: source, remote: "origin", destination: "main")
        await #expect(throws: GitInspectionError.self) {
            try await cli.perform(.push(plan), expected: snapshot) { _ in }
        }
        #expect(try host.git(["-C", bare, "rev-parse", "HEAD"]) == remoteHead)
        try host.write("remote.git/hooks/pre-receive", "#!/bin/sh\necho 'Rejected by fixture policy' >&2\nexit 1\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bare + "/hooks/pre-receive")
        let fresh = try await cli.snapshot(at: repo.root)
        let newPlan = try await cli.planPush(in: fresh, branch: source, remote: "origin", destination: "new")
        let output = PushOutput()
        await #expect(throws: GitInspectionError.self) {
            try await cli.perform(.push(newPlan), expected: fresh) { output.append($0) }
        }
        #expect(output.value.contains("Rejected by fixture policy"))
        #expect(try host.git(["-C", bare, "show-ref", "--verify", "refs/heads/new"], accepted: [128]).isEmpty)
    }

    @Test func changedAddressOrSourceMultipleURLsAndInvalidDestinationCannotSend() async throws {
        let repo = try RepositoryFixture(), host = try RepositoryFixture()
        defer {
            repo.remove()
            host.remove()
        }
        try repo.write("a", "base")
        try repo.git(["add", "."])
        try repo.git(["commit", "-m", "Base"])
        let bare = host.root + "/remote.git"
        try repo.git(["clone", "--bare", repo.root, bare])
        try repo.git(["remote", "add", "origin", bare])
        try repo.git(["branch", "other"])
        let cli = GitCLI(), snapshot = try await cli.snapshot(at: repo.root),
            source = try #require(snapshot.branches.first {
                $0.name == "other"
            })
        let plan = try await cli.planPush(in: snapshot, branch: source, remote: "origin", destination: "new")
        try repo.git(["config", "remote.origin.pushurl", host.root + "/missing"])
        await #expect(throws: GitInspectionError.failed("Push address changed since review; review Push again")) {
            try await cli.perform(.push(plan), expected: snapshot) { _ in }
        }
        try repo.git(["config", "--unset", "remote.origin.pushurl"])
        try repo.write("a", "next")
        try repo.git(["commit", "-am", "Next"])
        try repo.git(["update-ref", "refs/heads/other", "HEAD"])
        let fresh = try await cli.snapshot(at: repo.root)
        await #expect(throws: GitInspectionError
            .failed("Source branch changed since review; refresh and review Push again")) {
            try await cli.perform(.push(plan), expected: fresh) { _ in }
        }
        let current = try #require(fresh.branches.first { $0.name == "other" })
        for destination in ["", "-delete", ":main", "bad space", "../outside"] {
            await #expect(throws: GitInspectionError.self) {
                try await cli.planPush(in: fresh, branch: current, remote: "origin", destination: destination)
            }
        }
        try repo.git(["config", "--add", "remote.origin.pushurl", bare])
        try repo.git(["config", "--add", "remote.origin.pushurl", host.root + "/other.git"])
        await #expect(throws: GitInspectionError.self) {
            try await cli.planPush(in: fresh, branch: current, remote: "origin", destination: "new")
        }
        #expect(try host.git(["-C", bare, "show-ref", "--verify", "refs/heads/new"], accepted: [128]).isEmpty)
    }

    @Test func cancellationStopsPrePushChildAndReleasesTheSharedGate() async throws {
        let repo = try RepositoryFixture(), host = try RepositoryFixture()
        defer {
            repo.remove()
            host.remove()
        }
        try repo.write("a", "base")
        try repo.git(["add", "."])
        try repo.git(["commit", "-m", "Base"])
        let bare = host.root + "/remote.git"
        try repo.git(["clone", "--bare", repo.root, bare])
        try repo.git(["remote", "add", "origin", bare])
        try repo.write(".git/hooks/pre-push", "#!/bin/sh\n/bin/sleep 30 &\necho $! > '\(repo.root)/child.pid'\nwait\n")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: repo.root + "/.git/hooks/pre-push"
        )
        let cli = GitCLI(), snapshot = try await cli.snapshot(at: repo.root),
            source = try #require(snapshot.branches.first {
                $0.name == "main"
            })
        let plan = try await cli.planPush(in: snapshot, branch: source, remote: "origin", destination: "new")
        let task = Task { try await cli.perform(.push(plan), expected: snapshot) { _ in } }
        let deadline = ContinuousClock.now + .seconds(5)
        while !FileManager.default.fileExists(atPath: repo.root + "/child.pid"), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let pid =
            try #require(Int32(try String(contentsOfFile: repo.root + "/child.pid", encoding: .utf8)
                        .trimmingCharacters(in: .newlines)))
        await #expect(throws: GitInspectionError.failed("Another Git action is running for this repository")) {
            try await cli.perform(.push(plan), expected: snapshot) { _ in }
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        let end = ContinuousClock.now + .seconds(2)
        while kill(pid, 0) == 0, ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(10)) }
        #expect(kill(pid, 0) != 0)
        try FileManager.default.removeItem(atPath: repo.root + "/.git/hooks/pre-push")
        let fresh = try await cli.snapshot(at: repo.root)
        try await cli.perform(.push(plan), expected: fresh) { _ in }
        #expect(try host.git(["-C", bare, "rev-parse", "refs/heads/new"]) == Data((source.oid + "\n").utf8))
    }
}

private final class PushOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""

    func append(_ chunk: String) { lock.withLock { text += chunk } }

    var value: String { lock.withLock { text } }
}
