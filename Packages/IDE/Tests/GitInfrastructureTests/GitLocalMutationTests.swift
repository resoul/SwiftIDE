import Foundation
import Testing
import IDEApplication
@testable import GitInfrastructure

struct GitLocalMutationTests {
    private let git = GitCLI()

    private func perform(_ action: GitLocalAction, repo: RepositoryFixture) async throws {
        try await git.perform(action, expected: git.snapshot(at: repo.root), output: { _ in })
    }

    @Test func unbornStageUnstageAndCommitKeepDiskAndIncludeOnlyIndex() async throws {
        let repo = try RepositoryFixture()
        defer { repo.remove() }
        let path = ":(glob)*\nfile.txt"
        try repo.write(path, "staged bytes\n")
        var snapshot = try await git.snapshot(at: repo.root)
        let untracked = try #require(snapshot.changes.first { $0.path == path })
        try await git.perform(.stage(untracked), expected: snapshot, output: { _ in })
        snapshot = try await git.snapshot(at: repo.root)
        let staged = try #require(snapshot.changes.first { $0.path == path })
        #expect(staged.decoration.index == "A")
        try repo.write(path, "disk bytes after stage\n")
        snapshot = try await git.snapshot(at: repo.root)
        try await perform(.unstage(try #require(snapshot.changes.first { $0.path == path })), repo: repo)
        #expect(try String(contentsOfFile: repo.root + "/" + path, encoding: .utf8) == "disk bytes after stage\n")
        snapshot = try await git.snapshot(at: repo.root)
        #expect(snapshot.changes.first { $0.path == path }?.decoration.isUntracked == true)
        try await perform(.stage(try #require(snapshot.changes.first { $0.path == path })), repo: repo)
        try repo.write(path, "unstaged bytes\n")
        try repo.write("other.txt", "do not commit\n")
        try await perform(.commit("First commit\n\nMessage with $ and ` literals\n"), repo: repo)
        snapshot = try await git.snapshot(at: repo.root)
        #expect(snapshot.head != nil)
        #expect(snapshot.changes.first { $0.path == path }?.decoration.worktree == "M")
        #expect(snapshot.changes.first { $0.path == "other.txt" }?.decoration.isUntracked == true)
        let content = try repo.git(["show", "HEAD:" + path])
        #expect(String(decoding: content, as: UTF8.self) == "disk bytes after stage\n")
        #expect(String(decoding: try repo.git(["log", "-1", "--format=%B"]), as: UTF8.self)
            .contains("Message with $ and ` literals"))
    }

    @Test func unstageModificationRenameAndDeletionNeverRewritesWorktree() async throws {
        let repo = try RepositoryFixture()
        defer { repo.remove() }
        try repo.write("old.txt", "original\n")
        try repo.write("deleted.txt", "deleted\n")
        try repo.git(["add", "."])
        try repo.git(["commit", "-m", "Initial"])
        try repo.git(["mv", "old.txt", "new.txt"])
        var snapshot = try await git.snapshot(at: repo.root)
        let rename = try #require(snapshot.changes.first { $0.path == "new.txt" })
        try await git.perform(.unstage(rename), expected: snapshot, output: { _ in })
        #expect(!FileManager.default.fileExists(atPath: repo.root + "/old.txt"))
        #expect(try String(contentsOfFile: repo.root + "/new.txt", encoding: .utf8) == "original\n")
        snapshot = try await git.snapshot(at: repo.root)
        #expect(snapshot.changes.contains { $0.path == "old.txt" && $0.decoration.worktree == "D" })
        try FileManager.default.removeItem(atPath: repo.root + "/deleted.txt")
        snapshot = try await git.snapshot(at: repo.root)
        try await perform(.stage(try #require(snapshot.changes.first { $0.path == "deleted.txt" })), repo: repo)
        snapshot = try await git.snapshot(at: repo.root)
        try await perform(.unstage(try #require(snapshot.changes.first { $0.path == "deleted.txt" })), repo: repo)
        #expect(!FileManager.default.fileExists(atPath: repo.root + "/deleted.txt"))
    }

    @Test func branchCreationIsSeparateAndSwitchRefusesOverwritingDiskOrAnotherWorktree() async throws {
        let repo = try RepositoryFixture()
        defer { repo.remove() }
        try repo.write("a.txt", "base\n")
        try repo.git(["add", "."])
        try repo.git(["commit", "-m", "Base"])
        try await perform(.createBranch("feature/local"), repo: repo)
        var snapshot = try await git.snapshot(at: repo.root)
        #expect(snapshot.branch == "main")
        let feature = try #require(snapshot.branches.first { $0.name == "feature/local" })
        try await git.perform(.switchBranch(feature), expected: snapshot, output: { _ in })
        try repo.write("a.txt", "feature\n")
        try repo.git(["commit", "-am", "Feature"])
        try repo.git(["switch", "main"])
        try repo.write("a.txt", "local disk edit\n")
        snapshot = try await git.snapshot(at: repo.root)
        let newFeature = try #require(snapshot.branches.first { $0.name == "feature/local" })
        await #expect(throws: GitInspectionError.self) {
            try await git.perform(.switchBranch(newFeature), expected: snapshot, output: { _ in })
        }
        #expect(try String(contentsOfFile: repo.root + "/a.txt", encoding: .utf8) == "local disk edit\n")
        #expect(try await git.snapshot(at: repo.root).branch == "main")
        try repo.write("a.txt", "base\n")
        let link = repo.root + "-linked"
        defer { try? FileManager.default.removeItem(atPath: link) }
        try repo.git(["worktree", "add", link, "feature/local"])
        snapshot = try await git.snapshot(at: repo.root)
        await #expect(throws: GitInspectionError.self) {
            try await git.perform(.switchBranch(newFeature), expected: snapshot, output: { _ in })
        }
        await #expect(throws: GitInspectionError.self) { try await perform(.createBranch("-bad"), repo: repo) }
        await #expect(throws: GitInspectionError.failed("Invalid branch name")) {
            try await perform(.createBranch("bad name"), repo: repo)
        }
        await #expect(throws: GitInspectionError.self) { try await perform(.createBranch("feature/local"), repo: repo) }
    }

    @Test func staleIndexAndHeadAreRejectedBeforeMutation() async throws {
        let repo = try RepositoryFixture()
        defer { repo.remove() }
        try repo.write("a.txt", "first\n")
        try repo.git(["add", "."])
        let old = try await git.snapshot(at: repo.root)
        try repo.write("a.txt", "other staged\n")
        try repo.git(["add", "."])
        await #expect(throws: GitInspectionError
            .failed("Repository changed since review; refresh and retry the action")) {
            try await git.perform(.commit("Stale commit"), expected: old, output: { _ in })
        }
        #expect(try await git.snapshot(at: repo.root).head == nil)
        try await perform(.commit("Current"), repo: repo)
        await #expect(throws: GitInspectionError.self) {
            try await git.perform(.unstage(try #require(old.changes.first)), expected: old, output: { _ in })
        }
        await #expect(throws: GitInspectionError.self) { try await perform(.commit(" \n"), repo: repo) }
    }

    @Test func configuredHookFailureStreamsOutputAndRetainsStagedChanges() async throws {
        let repo = try RepositoryFixture()
        defer { repo.remove() }
        try repo.write("a.txt", "one\n")
        try repo.git(["add", "."])
        let hook = repo.root + "/.git/hooks/pre-commit"
        try "#!/bin/sh\necho 'hook explains failure' >&2\nexit 1\n".write(
            toFile: hook,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook)
        let output = CollectedOutput()
        let snapshot = try await git.snapshot(at: repo.root)
        await #expect(throws: GitInspectionError.self) {
            try await git.perform(.commit("Blocked"), expected: snapshot, output: { output.append($0) })
        }
        #expect(output.text.contains("hook explains failure"))
        let after = try await git.snapshot(at: repo.root)
        #expect(after.head == nil && after.changes.first?.decoration.index == "A")
    }

    @Test func cancellationStopsHookChildrenAndReleasesSharedMutationGate() async throws {
        let repo = try RepositoryFixture()
        defer { repo.remove() }
        try repo.write("a.txt", "one\n")
        try repo.git(["add", "."])
        let hook = repo.root + "/.git/hooks/pre-commit", marker = repo.root + "/.git/hook-running"
        try "#!/bin/sh\necho running\necho $$ > '\(marker)'\n/bin/sleep 30\n".write(
            toFile: hook,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook)
        let snapshot = try await git.snapshot(at: repo.root)
        let task = Task { try await git.perform(.commit("Cancelled"), expected: snapshot, output: { _ in }) }
        let deadline = ContinuousClock.now + .seconds(5)
        while !FileManager.default.fileExists(atPath: marker), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(FileManager.default.fileExists(atPath: marker))
        await #expect(throws: GitInspectionError.failed("Another Git action is running for this repository")) {
            try await git.perform(.commit("Concurrent"), expected: snapshot, output: { _ in })
        }
        let pid =
            try #require(Int32(String(contentsOfFile: marker, encoding: .utf8)
                        .trimmingCharacters(in: .whitespacesAndNewlines)))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(kill(pid, 0) != 0)
        try FileManager.default.removeItem(atPath: hook)
        try await perform(.commit("After cancellation"), repo: repo)
        #expect(try await git.snapshot(at: repo.root).head != nil)
    }
}

private final class CollectedOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var value = ""

    func append(_ text: String) { lock.withLock { value += text } }

    var text: String { lock.withLock { value } }
}
