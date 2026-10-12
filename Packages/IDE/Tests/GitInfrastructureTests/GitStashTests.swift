import Foundation
import IDEApplication
import Testing
@testable import GitInfrastructure

struct GitStashTests {
    private let cli = GitCLI()

    private func fixture() throws -> RepositoryFixture {
        let repo = try RepositoryFixture()
        try repo.write("a.txt", "base\n")
        try repo.write(".gitignore", "ignored/\n")
        try repo.git(["add", "."])
        try repo.git(["commit", "-m", "Base"])

        return repo
    }

    private func plan(_ request: GitStashRequest, repo: RepositoryFixture) async throws -> (GitSnapshot, GitStashPlan) {
        let snapshot = try await cli.snapshot(at: repo.root)
        let list = try await cli.stashes(in: snapshot.repository)
        let head = try #require(snapshot.head)

        return (snapshot, .init(
            repository: snapshot.repository,
            head: head,
            branch: snapshot.branch,
            listToken: list.token,
            request: request
        ))
    }

    private func perform(_ request: GitStashRequest, repo: RepositoryFixture, service: GitCLI? = nil) async throws {
        let (snapshot, plan) = try await plan(request, repo: repo)
        try await (service ?? cli).perform(.stash(plan), expected: snapshot, output: { _ in })
    }

    private func entries(_ repo: RepositoryFixture) async throws -> [GitStashEntry] {
        try await cli.stashes(in: cli.snapshot(at: repo.root).repository).entries
    }

    @Test func createAndApplyRestoreSeparateIndexAndWorktreeAndKeepTheEntry() async throws {
        let repo = try fixture()
        defer { repo.remove() }
        #expect(try await entries(repo).isEmpty)
        try repo.write("a.txt", "staged\n")
        try repo.git(["add", "a.txt"])
        try repo.write("a.txt", "worktree\n")
        let staged = try repo.git(["diff", "--cached"])
        let worktree = try repo.git(["diff"])
        try await perform(.create(message: "Draft\nwith second line", inclusion: .tracked), repo: repo)
        let entry = try #require(try await entries(repo).first)
        #expect(entry.message.contains("Draft with second line"))
        #expect(try repo.git(["diff"]).isEmpty && repo.git(["diff", "--cached"]).isEmpty)
        let preview = try await cli.diff(in: cli.snapshot(at: repo.root).repository, comparison: .stash(entry))
        #expect(preview.contains("worktree") && preview.contains("a.txt"))
        try await perform(.apply(entry, restoreIndex: true), repo: repo)
        #expect(try repo.git(["diff", "--cached"]) == staged)
        #expect(try repo.git(["diff"]) == worktree)
        #expect(try await entries(repo) == [entry])
    }

    @Test(arguments: GitStashInclusion.allCases)
    func inclusionIsExplicitAndUntrackedPreviewIncludesSavedExtraFiles(_ inclusion: GitStashInclusion) async throws {
        let repo = try fixture()
        defer { repo.remove() }
        try repo.write("a.txt", "tracked change\n")
        try repo.write("new space\nname.txt", "new content\n")
        try repo.write("ignored/cache.txt", "ignored content\n")
        try await perform(.create(message: "", inclusion: inclusion), repo: repo)
        let entry = try #require(try await entries(repo).first)
        #expect(FileManager.default.fileExists(atPath: repo.root + "/new space\nname.txt") == (inclusion == .tracked))
        #expect(FileManager.default.fileExists(atPath: repo.root + "/ignored/cache.txt") == (inclusion != .ignored))
        let preview = try await cli.diff(in: cli.snapshot(at: repo.root).repository, comparison: .stash(entry))
        #expect(preview.contains("new content") == (inclusion != .tracked))
        #expect(preview.contains("ignored content") == (inclusion == .ignored))
        try await perform(.apply(entry, restoreIndex: false), repo: repo)
        #expect(try String(contentsOfFile: repo.root + "/new space\nname.txt", encoding: .utf8) == "new content\n")
        #expect(try String(contentsOfFile: repo.root + "/ignored/cache.txt", encoding: .utf8) == "ignored content\n")
    }

    @Test func popRemovesOnlyReviewedNonTopEntryAndDefaultApplyIgnoresStashIndexConfiguration() async throws {
        let repo = try fixture()
        defer { repo.remove() }
        try repo.write("a.txt", "first\n")
        try repo.git(["add", "a.txt"])
        try await perform(.create(message: "first", inclusion: .tracked), repo: repo)
        try repo.write("a.txt", "second\n")
        try await perform(.create(message: "second", inclusion: .tracked), repo: repo)
        let list = try await entries(repo)
        try #require(list.count == 2)
        try repo.git(["config", "stash.index", "true"])
        try await perform(.pop(list[1], restoreIndex: false), repo: repo)
        #expect(try String(contentsOfFile: repo.root + "/a.txt", encoding: .utf8) == "first\n")
        #expect(try repo.git(["diff", "--cached"]).isEmpty)
        #expect(try await entries(repo).map(\.oid) == [list[0].oid])
    }

    @Test func conflictsRetainStashAndUseTheExistingSavedResultResolution() async throws {
        let repo = try fixture()
        defer { repo.remove() }
        try repo.write("a.txt", "stash side\n")
        try await perform(.create(message: "conflict", inclusion: .tracked), repo: repo)
        let entry = try #require(try await entries(repo).first)
        try repo.write("a.txt", "current branch\n")
        try repo.git(["commit", "-am", "Conflicting branch change"])
        do {
            try await perform(.pop(entry, restoreIndex: false), repo: repo)
            Issue.record("Expected stash conflict")
        } catch { #expect(error.localizedDescription.contains("not removed")) }
        let snapshot = try await cli.snapshot(at: repo.root)
        #expect(snapshot.changes.contains { $0.path == "a.txt" && $0.decoration.isConflict })
        #expect(try await entries(repo) == [entry])
        try repo.write("a.txt", "resolved\n")
        let conflict = try await cli.conflict(in: snapshot, path: "a.txt")
        try await cli.perform(.resolveConflict(conflict, .workingFile), expected: snapshot, output: { _ in })
        #expect(try await cli.snapshot(at: repo.root).changes.allSatisfy { !$0.decoration.isConflict })
        #expect(try await entries(repo) == [entry])
    }

    @Test func staleListAndDirtyTrackedFilesRefuseWithoutDroppingAnything() async throws {
        let repo = try fixture()
        defer { repo.remove() }
        try repo.write("a.txt", "saved\n")
        try await perform(.create(message: "saved", inclusion: .tracked), repo: repo)
        let entry = try #require(try await entries(repo).first)
        let (snapshot, reviewed) = try await plan(.drop(entry), repo: repo)
        // Same commit appears twice; OID equality alone cannot protect the reflog selection.
        try repo.git(["reflog", "write", "refs/stash", entry.oid, entry.oid, "Another entry"])
        await #expect(throws: GitInspectionError.self) {
            try await cli.perform(.stash(reviewed), expected: snapshot, output: { _ in })
        }
        #expect(try await entries(repo).count == 2)
        try repo.write("a.txt", "dirty tracked\n")
        let fresh = try #require(try await entries(repo).first)
        await #expect(throws: GitInspectionError.self) {
            try await perform(.apply(fresh, restoreIndex: false), repo: repo)
        }
        #expect(try await entries(repo).count == 2)
        #expect(try String(contentsOfFile: repo.root + "/a.txt", encoding: .utf8) == "dirty tracked\n")
        try await perform(.drop(fresh), repo: repo)
        #expect(try await entries(repo).count == 1)
        #expect(try String(contentsOfFile: repo.root + "/a.txt", encoding: .utf8) == "dirty tracked\n")
    }

    @Test(arguments: [false, true])
    func untrackedOrIgnoredCollisionsRefuseBeforeWriting(ignored: Bool) async throws {
        let repo = try fixture()
        defer { repo.remove() }
        let path = ignored ? "ignored/cache.txt" : "new.txt"
        try repo.write("a.txt", "saved\n")
        try repo.write(path, "saved extra\n")
        try await perform(.create(message: "extra", inclusion: .ignored), repo: repo)
        let entry = try #require(try await entries(repo).first)
        try repo.write(path, "keep this\n")
        await #expect(throws: GitInspectionError.self) {
            try await perform(.pop(entry, restoreIndex: false), repo: repo)
        }
        #expect(try String(contentsOfFile: repo.root + "/a.txt", encoding: .utf8) == "base\n")
        #expect(try String(contentsOfFile: repo.root + "/" + path, encoding: .utf8) == "keep this\n")
        #expect(try await entries(repo) == [entry])
    }

    @Test func listChangeAfterApplyKeepsBothEntriesInsteadOfPoppingTheNewTop() async throws {
        let repo = try fixture()
        defer { repo.remove() }
        try repo.write("a.txt", "saved\n")
        try await perform(.create(message: "saved", inclusion: .tracked), repo: repo)
        let entry = try #require(try await entries(repo).first)
        let wrapper = repo.root + "-git"
        defer { try? FileManager.default.removeItem(atPath: wrapper) }
        let script = """
        #!/bin/sh
        /usr/bin/git "$@"
        result=$?
        case " $* " in
        *" stash apply "*)
          /usr/bin/git -C '\(repo.root)' reflog write refs/stash '\(entry.oid)' '\(entry.oid)' concurrent ;;
        esac
        exit "$result"
        """
        try script.write(toFile: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper)
        let wrapped = GitCLI(executable: URL(fileURLWithPath: wrapper))
        await #expect(throws: GitInspectionError.self) {
            try await perform(.pop(entry, restoreIndex: false), repo: repo, service: wrapped)
        }
        #expect(try String(contentsOfFile: repo.root + "/a.txt", encoding: .utf8) == "saved\n")
        #expect(try await entries(repo).count == 2)
    }

    @Test func cancelledApplyRetainsEntryEvenWhenFilesWereAlreadyApplied() async throws {
        let repo = try fixture()
        defer { repo.remove() }
        try repo.write("a.txt", "saved\n")
        try await perform(.create(message: "saved", inclusion: .tracked), repo: repo)
        let entry = try #require(try await entries(repo).first)
        let (snapshot, reviewed) = try await plan(.pop(entry, restoreIndex: false), repo: repo)
        let wrapper = repo.root + "-git"
        defer { try? FileManager.default.removeItem(atPath: wrapper) }
        let script = """
        #!/bin/sh
        /usr/bin/git "$@"
        result=$?
        case " $* " in
        *" stash apply "*) touch '\(repo.root)/applied'; sleep 20 ;;
        esac
        exit "$result"
        """
        try script.write(toFile: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper)
        let wrapped = GitCLI(executable: URL(fileURLWithPath: wrapper))
        let task = Task { try await wrapped.perform(.stash(reviewed), expected: snapshot, output: { _ in }) }
        let end = ContinuousClock.now + .seconds(10)
        while !FileManager.default.fileExists(atPath: repo.root + "/applied"), ContinuousClock.now < end {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(FileManager.default.fileExists(atPath: repo.root + "/applied"))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try String(contentsOfFile: repo.root + "/a.txt", encoding: .utf8) == "saved\n")
        #expect(try await entries(repo) == [entry])
    }

    @Test func noEligibleChangesAndActiveIntegrationCannotCreateStash() async throws {
        let repo = try fixture()
        defer { repo.remove() }
        await #expect(throws: GitInspectionError.self) {
            try await perform(.create(message: "empty", inclusion: .tracked), repo: repo)
        }
        #expect(try await entries(repo).isEmpty)
        try repo.write("a.txt", "dirty\n")
        let head = try #require(try await cli.snapshot(at: repo.root).head)
        try repo.write(".git/MERGE_HEAD", head + "\n")
        await #expect(throws: GitInspectionError.self) {
            try await perform(.create(message: "merge", inclusion: .tracked), repo: repo)
        }
        #expect(try await entries(repo).isEmpty)
        #expect(try String(contentsOfFile: repo.root + "/a.txt", encoding: .utf8) == "dirty\n")
    }

    @Test func untrackedOnlyStashRestoresBinaryBytesAndRefusesAChangedHead() async throws {
        let repo = try fixture()
        defer { repo.remove() }
        let path = URL(fileURLWithPath: repo.root + "/binary.dat")
        let bytes = Data([0, 255, 3, 4, 0, 100])
        try bytes.write(to: path)
        try await perform(.create(message: "binary only", inclusion: .untracked), repo: repo)
        let entry = try #require(try await entries(repo).first)
        #expect(!FileManager.default.fileExists(atPath: path.path))
        let preview = try await cli.diff(in: cli.snapshot(at: repo.root).repository, comparison: .stash(entry))
        #expect(preview.contains("Binary files"))
        let (snapshot, reviewed) = try await plan(.pop(entry, restoreIndex: false), repo: repo)
        try repo.write("a.txt", "new commit\n")
        try repo.git(["commit", "-am", "Move HEAD"])
        await #expect(throws: GitInspectionError.self) {
            try await cli.perform(.stash(reviewed), expected: snapshot, output: { _ in })
        }
        #expect(try await entries(repo) == [entry] && !FileManager.default.fileExists(atPath: path.path))
        try await perform(.pop(entry, restoreIndex: false), repo: repo)
        #expect(try Data(contentsOf: path) == bytes)
        #expect(try await entries(repo).isEmpty)
    }

    @Test func symbolicStashRefAndChangedSubmoduleWorktreesAreRefused() async throws {
        let repo = try fixture()
        let module = try fixture()
        defer {
            repo.remove()
            module.remove()
        }
        try repo.git(["symbolic-ref", "refs/stash", "refs/heads/main"])
        let repository = try await cli.snapshot(at: repo.root).repository
        await #expect(throws: GitInspectionError.self) { try await cli.stashes(in: repository) }
        try repo.git(["symbolic-ref", "--delete", "refs/stash"])
        try repo.git(["-c", "protocol.file.allow=always", "submodule", "add", module.root, "Module"])
        try repo.git(["commit", "-m", "Add submodule"])
        try repo.write("Module/a.txt", "dirty module\n")
        try repo.write("a.txt", "dirty root\n")
        await #expect(throws: GitInspectionError.self) {
            try await perform(.create(message: "submodule", inclusion: .tracked), repo: repo)
        }
        #expect(try await entries(repo).isEmpty)
        #expect(try String(contentsOfFile: repo.root + "/Module/a.txt", encoding: .utf8) == "dirty module\n")
    }

    @Test func stashListIsBoundedAndDuplicateObjectsHaveDistinctSelectionKeys() async throws {
        let repo = try fixture()
        defer { repo.remove() }
        try repo.write("a.txt", "saved\n")
        try await perform(.create(message: "saved", inclusion: .tracked), repo: repo)
        let entry = try #require(try await entries(repo).first)
        for i in 0..<201 { try repo.git(["reflog", "write", "refs/stash", entry.oid, entry.oid, "Entry \(i)"]) }
        let list = try await cli.stashes(in: cli.snapshot(at: repo.root).repository)
        #expect(list.entries.count == 200 && list.hasMore)
        #expect(Set(list.entries.map(\.key)).count == 200)
        #expect(list.entries.last?.selector == "stash@{199}")
    }
}
