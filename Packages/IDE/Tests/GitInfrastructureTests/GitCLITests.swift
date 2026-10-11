import Foundation
import Testing
import IDEApplication
@testable import GitInfrastructure

struct GitCLITests {
    @Test func realStatusKeepsBothSidesRenamesUnusualPathsAndIgnoreRules() async throws {
        let repo = try RepositoryFixture()
        defer { repo.remove() }
        try repo.write("tracked.txt", "first\n"); try repo.write("old name.txt", "rename\n")
        try repo.write(".gitignore", "generated/\n!keep.txt\n")
        try repo.git(["add", "."]); try repo.git(["commit", "-m", "Initial"])
        let head = String(decoding: try repo.git(["rev-parse", "HEAD"]), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        try repo.git(["update-ref", "refs/remotes/origin/main", head])
        try repo.git(["config", "remote.origin.url", repo.root])
        try repo.git(["config", "remote.origin.fetch", "+refs/heads/*:refs/remotes/origin/*"])
        try repo.git(["config", "branch.main.remote", "origin"])
        try repo.git(["config", "branch.main.merge", "refs/heads/main"])
        try repo.write("tracked.txt", "staged\n"); try repo.git(["add", "tracked.txt"])
        try repo.write("tracked.txt", "staged\nunstaged\n")
        try repo.git(["mv", "old name.txt", "new name.txt"])
        try repo.write("new\nquoted\".txt", "new\n"); try repo.write("generated/nested/file.txt", "ignored\n")
        let snapshot = try await GitCLI().snapshot(at: repo.root)
        let tracked = try #require(snapshot.changes.first { $0.path == "tracked.txt" })
        #expect(tracked.decoration.index == "M" && tracked.decoration.worktree == "M")
        #expect(snapshot.changes.contains { $0.path == "new\nquoted\".txt" && $0.decoration.isUntracked })
        #expect(snapshot.changes.contains { $0.path == "new name.txt" && $0.previousPath == "old name.txt" })
        let ignored = try #require(snapshot.changes.first { $0.path == "generated" })
        #expect(ignored.decoration.ignoredReason?.contains(".gitignore:1") == true)
        #expect(snapshot.decorations[DocumentPath.canonical(repo.root)]?.tone == .blue)
        #expect(snapshot.branches.contains { $0.reference == "refs/heads/main" })
        #expect(snapshot.branches.contains { $0.isRemote && $0.name == "origin/main" })
        #expect(snapshot.upstream == "origin/main" && snapshot.ahead == 0 && snapshot.behind == 0)
        let staged = try await GitCLI().diff(in: snapshot.repository, comparison: .index(tracked))
        let unstaged = try await GitCLI().diff(in: snapshot.repository, comparison: .worktree(tracked))
        #expect(staged.contains("+staged") && !staged.contains("+unstaged"))
        #expect(unstaged.contains("+unstaged"))
    }

    @Test func unbornDetachedAndLinkedWorktreeUseGitReportedIdentity() async throws {
        let repo = try RepositoryFixture(); defer { repo.remove() }
        let empty = try await GitCLI().snapshot(at: repo.root)
        #expect(empty.head == nil && empty.branch == "main")
        try repo.write("a.txt", "one\n"); try repo.git(["add", "."]); try repo.git(["commit", "-m", "One"])
        let link = repo.root + "-worktree"
        defer { try? FileManager.default.removeItem(atPath: link) }
        try repo.git(["worktree", "add", "-b", "linked", link])
        let linked = try await GitCLI().snapshot(at: link)
        #expect(linked.repository.root == DocumentPath.canonical(link))
        #expect(linked.repository.gitDirectory != linked.repository.commonDirectory)
        #expect(linked.branch == "linked")
        try repo.git(["checkout", "--detach"])
        let detached = try await GitCLI().snapshot(at: repo.root)
        #expect(detached.branch == nil && detached.head != nil)
    }

    @Test func historyIsAnchoredPaginatedAndRootCommitHasFilesAndDiff() async throws {
        let repo = try RepositoryFixture(); defer { repo.remove() }
        for i in 0..<4 {
            try repo.write("a.txt", "\(i)\n"); try repo.git(["add", "."]); try repo.git(["commit", "-m", "Commit \(i)"])
        }
        let service = GitCLI(), snapshot = try await service.snapshot(at: repo.root)
        let head = try #require(snapshot.head)
        let first = try await service.history(in: snapshot.repository, revision: head, offset: 0, count: 2)
        #expect(first.commits.count == 2 && first.hasMore)
        try repo.write("a.txt", "later\n"); try repo.git(["add", "."]); try repo.git(["commit", "-m", "Later"])
        let second = try await service.history(in: snapshot.repository, revision: head, offset: 2, count: 2)
        #expect(second.commits.count == 2 && !second.hasMore)
        #expect(Set(first.commits.map(\.oid)).isDisjoint(with: second.commits.map(\.oid)))
        let root = try #require(second.commits.last), files = try await service.files(in: snapshot.repository, commit: root)
        #expect(root.parents.isEmpty && files.map(\.path) == ["a.txt"])
        let diff = try await service.diff(in: snapshot.repository, comparison: .commit(root, try #require(files.first)))
        #expect(diff.contains("+0"))
    }

    @Test func diffDisablesExternalProgramsAndTreatsMagicPathLiterally() async throws {
        let repo = try RepositoryFixture(); defer { repo.remove() }
        let path = ":(glob)*.txt"
        try repo.write(path, "before\n"); try repo.write("ordinary.txt", "ordinary\n")
        try repo.git(["add", "."]); try repo.git(["commit", "-m", "Initial"])
        try repo.write(".gitattributes", "*.txt diff=custom\n")
        let marker = repo.root + "/executed"
        try repo.write("driver", "#!/bin/sh\ntouch '\(marker)'\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: repo.root + "/driver")
        try repo.git(["config", "diff.external", repo.root + "/driver"])
        try repo.git(["config", "diff.custom.textconv", repo.root + "/driver"])
        try repo.write(path, "after\n"); try repo.write("ordinary.txt", "also changed\n")
        let snapshot = try await GitCLI().snapshot(at: repo.root)
        let change = try #require(snapshot.changes.first { $0.path == path })
        let diff = try await GitCLI().diff(in: snapshot.repository, comparison: .worktree(change))
        #expect(diff.contains("+after") && !diff.contains("+also changed"))
        #expect(!FileManager.default.fileExists(atPath: marker))
        try repo.write("binary.bin", String(repeating: "\0", count: 100))
        let binary = GitChange(path: "binary.bin", decoration: .init(isUntracked: true))
        #expect(try await GitCLI().diff(in: snapshot.repository, comparison: .untracked(binary)).contains("Binary files"))
    }

    @Test func conflictsRemainDistinctFromUntrackedAndRenameCommitKeepsBothPaths() async throws {
        let repo = try RepositoryFixture(); defer { repo.remove() }
        try repo.write("a.txt", "base\n"); try repo.git(["add", "."]); try repo.git(["commit", "-m", "Base"])
        try repo.git(["checkout", "-b", "other"])
        try repo.write("a.txt", "other\n"); try repo.git(["commit", "-am", "Other"])
        try repo.git(["checkout", "main"])
        try repo.write("a.txt", "main\n"); try repo.git(["commit", "-am", "Main"])
        try repo.git(["merge", "other"], accepted: [1])
        let snapshot = try await GitCLI().snapshot(at: repo.root)
        #expect(snapshot.changes.contains { $0.path == "a.txt" && $0.decoration.isConflict && !$0.decoration.isUntracked })
        try repo.git(["merge", "--abort"])
        try repo.git(["mv", "a.txt", "renamed.txt"]); try repo.git(["commit", "-m", "Rename"])
        let newer = try await GitCLI().snapshot(at: repo.root)
        let page = try await GitCLI().history(in: newer.repository, revision: try #require(newer.head), offset: 0, count: 1)
        let commit = try #require(page.commits.first)
        let files = try await GitCLI().files(in: newer.repository, commit: commit)
        #expect(files.contains { $0.path == "renamed.txt" && $0.previousPath == "a.txt" && $0.status.hasPrefix("R") })
    }

    @Test func boundedProcessReportsFailuresSizeTimeoutAndCancellation() async throws {
        let repo = try RepositoryFixture(); defer { repo.remove() }
        let missing = GitCLI(executable: URL(fileURLWithPath: "/does-not-exist/git"))
        await #expect(throws: GitInspectionError.self) { try await missing.snapshot(at: repo.root) }
        let outside = repo.root + "-outside"
        try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: outside) }
        await #expect(throws: GitInspectionError.unavailable("This folder is not in a Git repository")) { try await GitCLI().snapshot(at: outside) }
        await #expect(throws: GitInspectionError.self) {
            try await GitCommand.run(executable: URL(fileURLWithPath: "/usr/bin/git"), root: repo.root, arguments: ["--version"], limit: 1)
        }
        let hang = "trap '' TERM; while :; do :; done"
        await #expect(throws: GitInspectionError.self) {
            try await GitCommand.run(executable: URL(fileURLWithPath: "/bin/sh"), root: repo.root, arguments: ["-c", hang], timeout: 0.05)
        }
        let task = Task { try await GitCommand.run(executable: URL(fileURLWithPath: "/bin/sh"), root: repo.root, arguments: ["-c", hang], timeout: 10) }
        try await Task.sleep(for: .milliseconds(30)); task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test(arguments: [false, true]) func timedOutSubprocessCannotLeaveAChildHoldingTheOutputPipe(parentExits: Bool) async throws {
        let repo = try RepositoryFixture(); defer { repo.remove() }
        let spawn = "/bin/sleep 20 &\necho $! > '\(repo.root)/child.pid'\n" + (parentExits ? "exit 0\n" : "wait\n")
        let started = ContinuousClock.now
        await #expect(throws: GitInspectionError.failed("Git request timed out")) {
            try await GitCommand.run(executable: URL(fileURLWithPath: "/bin/sh"), root: repo.root, arguments: ["-c", spawn], timeout: 0.5)
        }
        #expect(started.duration(to: .now) < .seconds(3))
        let pidText = try String(contentsOfFile: repo.root + "/child.pid", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try #require(Int32(pidText))
        let end = ContinuousClock.now + .seconds(2)
        while kill(pid, 0) == 0, ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(10)) }
        #expect(kill(pid, 0) != 0)
    }
}

final class RepositoryFixture: @unchecked Sendable {
    let root = DocumentPath.canonical("/private/tmp/swiftide-git-\(UUID())")

    init() throws {
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try git(["init", "-b", "main"])
        try git(["config", "user.name", "Test Author"]); try git(["config", "user.email", "author@example.test"])
        try git(["config", "commit.gpgsign", "false"])
    }

    func remove() { try? FileManager.default.removeItem(atPath: root) }
    func write(_ path: String, _ value: String) throws {
        let url = URL(fileURLWithPath: root + "/" + path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try value.write(to: url, atomically: true, encoding: .utf8)
    }
    @discardableResult func git(_ arguments: [String], accepted: Set<Int32> = [0]) throws -> Data {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root] + arguments
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard accepted.contains(process.terminationStatus) else { throw GitInspectionError.failed("Fixture command failed: \(arguments)") }

        return data
    }
}
