import Foundation
import IDEApplication
import Testing
@testable import GitInfrastructure

struct GitTrackingTests {
    private let cli = GitCLI()

    private func fixture() throws -> RepositoryFixture {
        let repo = try RepositoryFixture()
        try repo.write("a.txt", "base\n")
        try repo.git(["add", "."])
        try repo.git(["commit", "-m", "Base"])
        try repo.git(["remote", "add", "origin", "https://example.invalid/repository.git"])
        try repo.git(["update-ref", "refs/remotes/origin/release/remote", "HEAD"])

        return repo
    }

    private func apply(_ request: GitTrackingRequest, repo: RepositoryFixture) async throws {
        let snapshot = try await cli.snapshot(at: repo.root)
        let plan = try await cli.planTracking(in: snapshot, request: request)
        try await cli.perform(.tracking(plan), expected: snapshot, output: { _ in })
    }

    private func branch(_ ref: String, repo: RepositoryFixture) async throws -> GitBranch {
        try #require(try await cli.snapshot(at: repo.root).branches.first { $0.reference == ref })
    }

    private func refused(_ action: () async throws -> Void) async {
        do {
            try await action()
            Issue.record("Expected tracking refusal")
        } catch {}
    }

    @Test func createChangeRemoveTrackingKeepCheckoutIndexAndDirtyFiles() async throws {
        let repo = try fixture()
        defer { repo.remove() }
        try repo.write("a.txt", "staged\n")
        try repo.git(["add", "a.txt"])
        try repo.write("a.txt", "unstaged\n")
        let index = try repo.git(["diff", "--cached"])
        let source = try await branch("refs/remotes/origin/release/remote", repo: repo)
        try repo.git(["config", "branch.autoSetupRebase", "always"])
        try await apply(.create(name: "feature/local", source: source), repo: repo)
        #expect(try repo.git(["config", "--get", "branch.feature/local.rebase"], accepted: [0, 1]).isEmpty)
        var local = try await branch("refs/heads/feature/local", repo: repo)
        #expect(local.oid == source.oid && local.upstream == source.reference)
        #expect(local.upstreamRemote == "origin" && local.upstreamSource == "refs/heads/release/remote")
        #expect(try await cli.snapshot(at: repo.root).branch == "main")
        try repo.git(["update-ref", "refs/remotes/origin/another", "HEAD"])
        let other = try await branch("refs/remotes/origin/another", repo: repo)
        try await apply(.set(branch: local, target: other), repo: repo)
        local = try await branch(local.reference, repo: repo)
        #expect(local.upstreamSource == "refs/heads/another")
        try repo.git(["update-ref", "-d", "refs/remotes/origin/another"])
        local = try await branch(local.reference, repo: repo)
        #expect(local.upstreamSource == "refs/heads/another", "configured source survives a missing fetched ref")
        try await apply(.remove(branch: local), repo: repo)
        local = try await branch(local.reference, repo: repo)
        #expect(local.upstream.isEmpty && local.upstreamRemote.isEmpty && local.upstreamSource.isEmpty)
        #expect(try repo.git(["diff", "--cached"]) == index)
        #expect(try String(contentsOfFile: repo.root + "/a.txt", encoding: .utf8) == "unstaged\n")
    }

    @Test func changedRefOrConfigurationAndDuplicateNamesRefuseBeforeCreating() async throws {
        let repo = try fixture()
        defer { repo.remove() }
        var snapshot = try await cli.snapshot(at: repo.root)
        let source = try #require(snapshot.branches.first { $0.isRemote })
        let plan = try await cli.planTracking(in: snapshot, request: .create(name: "reviewed", source: source))
        try repo.git(["config", "remote.origin.fetch", "+refs/heads/*:refs/remotes/origin/new/*"])
        await refused { try await cli.perform(.tracking(plan), expected: snapshot, output: { _ in }) }
        #expect(try await cli.snapshot(at: repo.root).branches.allSatisfy { $0.name != "reviewed" })
        try repo.git(["config", "remote.origin.fetch", "+refs/heads/*:refs/remotes/origin/*"])
        try repo.write("a.txt", "next\n")
        try repo.git(["commit", "-am", "Next"])
        snapshot = try await cli.snapshot(at: repo.root)
        let stale = try await cli.planTracking(in: snapshot, request: .create(name: "moved", source: source))
        try repo.git(["update-ref", source.reference, "HEAD"])
        await refused { try await cli.perform(.tracking(stale), expected: snapshot, output: { _ in }) }
        let freshSource = try await branch(source.reference, repo: repo)
        await refused { _ = try await cli.planTracking(
            in: cli.snapshot(at: repo.root),
            request: .create(name: "main", source: freshSource)
        ) }
        try repo.git(["config", "branch.orphan.remote", "origin"])
        await refused { _ = try await cli.planTracking(
            in: cli.snapshot(at: repo.root),
            request: .create(name: "orphan", source: freshSource)
        ) }
    }

    @Test func fetchMappingsHandleSlashRemotesExactRefsAmbiguityNegativesAndHeadAliases() async throws {
        let repo = try fixture()
        defer { repo.remove() }
        try repo.git(["remote", "add", "team/fork", "https://example.invalid/fork.git"])
        try repo.git(["config", "remote.team/fork.fetch", "+refs/heads/feature/actual:refs/remotes/team/fork/fetched"])
        try repo.git(["update-ref", "refs/remotes/team/fork/fetched", "HEAD"])
        let source = try await branch("refs/remotes/team/fork/fetched", repo: repo)
        try await apply(.create(name: "exact", source: source), repo: repo)
        #expect(try await branch("refs/heads/exact", repo: repo).upstreamSource == "refs/heads/feature/actual")
        #expect(try await branch("refs/heads/exact", repo: repo).upstreamRemote == "team/fork")
        try repo.git(["remote", "add", "alias", "https://example.invalid/alias.git"])
        try repo.git(["config", "remote.alias.fetch", "+refs/heads/*:refs/remotes/team/fork/*"])
        await refused { _ = try await cli.planTracking(
            in: cli.snapshot(at: repo.root),
            request: .create(name: "ambiguous", source: source)
        ) }
        try repo.git(["remote", "remove", "alias"])
        // Removing a remote may prune refs from its overlapping destination; restore the explicit fixture ref.
        try repo.git(["update-ref", source.reference, "HEAD"])
        try repo.git(["config", "--add", "remote.team/fork.fetch", "^refs/heads/feature/*"])
        await refused { _ = try await cli.planTracking(
            in: cli.snapshot(at: repo.root),
            request: .create(name: "excluded", source: source)
        ) }
        try repo.git(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/release/remote"])
        let alias = try await branch("refs/remotes/origin/HEAD", repo: repo)
        await refused { _ = try await cli.planTracking(
            in: cli.snapshot(at: repo.root),
            request: .create(name: "head-alias", source: alias)
        ) }
    }

    @Test func branchesOwnedByOtherWorktreesAndPerWorktreeConfigurationRefuse() async throws {
        let repo = try fixture()
        defer { repo.remove() }
        let otherRoot = repo.root + "-linked"
        defer { try? FileManager.default.removeItem(atPath: otherRoot) }
        try repo.git(["worktree", "add", "-b", "owned", otherRoot])
        let source = try await branch("refs/remotes/origin/release/remote", repo: repo)
        let owned = try await branch("refs/heads/owned", repo: repo)
        await refused { _ = try await cli.planTracking(
            in: cli.snapshot(at: repo.root),
            request: .set(branch: owned, target: source)
        ) }
        #expect(try await branch(owned.reference, repo: repo).upstream.isEmpty)
        try repo.git(["config", "extensions.worktreeConfig", "true"])
        await refused { _ = try await cli.planTracking(
            in: cli.snapshot(at: repo.root),
            request: .create(name: "unsupported", source: source)
        ) }
    }

    @Test func cancelledActionWritesNothingAndCreationUsesReviewedSourceCommit() async throws {
        let repo = try fixture()
        defer { repo.remove() }
        let source = try await branch("refs/remotes/origin/release/remote", repo: repo)
        let snapshot = try await cli.snapshot(at: repo.root)
        let plan = try await cli.planTracking(in: snapshot, request: .create(name: "cancelled", source: source))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await cli.perform(.tracking(plan), expected: snapshot, output: { _ in })
        }
        do {
            try await task.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {} catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(try await cli.snapshot(at: repo.root).branches.allSatisfy { $0.name != "cancelled" })
        try repo.write("a.txt", "new HEAD\n")
        try repo.git(["commit", "-am", "New HEAD"])
        try await apply(.create(name: "from-remote", source: source), repo: repo)
        #expect(try await branch("refs/heads/from-remote", repo: repo).oid == source.oid)
        #expect(try await cli.snapshot(at: repo.root).head != source.oid)
    }

    @Test func trackingFailureAfterBranchCreationReportsAndRetainsThePartialResult() async throws {
        let repo = try fixture()
        defer { repo.remove() }
        let hook = repo.root + "/.git/hooks/reference-transaction"
        try "#!/bin/sh\nif [ \"$1\" = committed ]; then touch .git/config.lock; fi\nexit 0\n".write(
            toFile: hook,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook)
        let source = try await branch("refs/remotes/origin/release/remote", repo: repo)
        do {
            try await apply(.create(name: "partial", source: source), repo: repo)
            Issue.record("Expected tracking configuration failure")
        } catch {
            #expect(error.localizedDescription.contains("branch was created") && error.localizedDescription
                .contains("retained"))
        }
        let partial = try await branch("refs/heads/partial", repo: repo)
        #expect(partial.oid == source.oid && partial.upstream.isEmpty)
        #expect(try await cli.snapshot(at: repo.root).branch == "main")
    }
}
