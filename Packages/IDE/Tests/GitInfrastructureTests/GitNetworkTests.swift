import Foundation
import Testing
import IDEApplication
@testable import GitInfrastructure

struct GitNetworkTests {
    @Test func configuredCredentialHelperStillWorksAndMissingCredentialsCannotPrompt() async throws {
        let repo = try RepositoryFixture(); defer { repo.remove() }
        try repo.write("credential-helper", "#!/bin/sh\necho username=fixture\necho password=fixture-password\necho \"$1:$GIT_TERMINAL_PROMPT:$GIT_ASKPASS:$SSH_ASKPASS_REQUIRE\" > '\(repo.root)/helper-called'\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: repo.root + "/credential-helper")
        let input = Data("protocol=https\nhost=example.invalid\n\n".utf8)
        let result = try await GitCommand.run(executable: URL(fileURLWithPath: "/usr/bin/git"),
                                              root: repo.root,
                                              arguments: ["-c", "credential.helper=", "-c", "credential.helper=" + repo.root + "/credential-helper", "credential", "fill"],
                                              input: input,
                                              network: true)
        #expect(result.status == 0 && String(decoding: result.output, as: UTF8.self).contains("password=fixture-password"))
        #expect(try String(contentsOfFile: repo.root + "/helper-called", encoding: .utf8) == "get:0:/usr/bin/false:never\n")
        let missing = try await GitCommand.run(executable: URL(fileURLWithPath: "/usr/bin/git"),
                                               root: repo.root,
                                               arguments: ["-c", "credential.helper=", "credential", "fill"],
                                               input: input,
                                               timeout: 3,
                                               network: true)
        #expect(missing.status != 0 && missing.error.contains("could not read Username"))
    }
    @Test func cloneAndExplicitFetchUpdateRemoteRefsWithoutTouchingLocalFilesOrIndex() async throws {
        let remote = try RepositoryFixture(), host = try RepositoryFixture()
        defer { remote.remove(); host.remove() }
        try remote.write("a.txt", "initial\n"); try remote.git(["add", "."]); try remote.git(["commit", "-m", "Initial"])
        try remote.git(["branch", "obsolete"])
        let bare = host.root + "/remote.git"
        try remote.git(["clone", "--bare", remote.root, bare])
        let cli = GitCLI()
        let path = try await cli.clone(.init(source: bare, parent: host.root, name: "clone with spaces")) { _ in }
        let initial = try await cli.snapshot(at: path)
        #expect(initial.remotes == ["origin"] && initial.upstream == "origin/main")
        let file = path + "/a.txt"
        try "staged\n".write(toFile: file, atomically: true, encoding: .utf8)
        let changed = try await cli.snapshot(at: path)
        try await cli.perform(.stage(try #require(changed.changes.first)), expected: changed) { _ in }
        try "dirty\n".write(toFile: file, atomically: true, encoding: .utf8)
        try remote.write("a.txt", "remote\n"); try remote.git(["commit", "-am", "Remote"])
        try remote.git(["push", bare, "main"])
        try remote.git(["push", bare, "--delete", "obsolete"])
        try remote.git(["tag", "new-tag"])
        try remote.git(["push", bare, "refs/tags/new-tag"])
        // A dangerous project refspec must not be followed by this UI's Fetch action.
        try host.git(["-C", path, "config", "remote.origin.fetch", "+refs/heads/*:refs/heads/*"])
        let reviewed = try await cli.snapshot(at: path)
        try await cli.perform(.fetch("origin"), expected: reviewed) { _ in }
        try host.git(["-C", path, "config", "remote.origin.fetch", "+refs/heads/*:refs/remotes/origin/*"])
        let after = try await cli.snapshot(at: path)
        #expect(after.branches.contains { $0.name == "origin/obsolete" }, "Fetch does not prune deleted remote branches")
        #expect(try host.git(["-C", path, "show-ref", "--verify", "refs/tags/new-tag"], accepted: [1, 128]).isEmpty, "Fetch does not update tags")
        #expect(!FileManager.default.fileExists(atPath: after.repository.gitDirectory + "/FETCH_HEAD"))
        #expect(after.head == initial.head && after.branch == "main")
        #expect(after.changes == reviewed.changes && after.behind == 1)
        #expect(try String(contentsOfFile: file, encoding: .utf8) == "dirty\n")
        #expect(String(decoding: try host.git(["-C", path, "show", ":a.txt"]), as: UTF8.self) == "staged\n")
        #expect(after.branches.first { $0.name == "origin/main" }?.oid != initial.head)
        await #expect(throws: GitInspectionError.self) { try await cli.perform(.fetch("missing"), expected: after) { _ in } }
    }

    @Test func destinationIsExclusiveAndCredentialsAndUnsupportedTransportsAreRejected() async throws {
        let repo = try RepositoryFixture(); defer { repo.remove() }
        try repo.write("existing/precious", "keep")
        let cli = GitCLI()
        for name in ["existing", ".git", "link"] {
            if name == "link" { try FileManager.default.createSymbolicLink(atPath: repo.root + "/link", withDestinationPath: repo.root + "/absent") }
            await #expect(throws: (any Error).self) { try await cli.clone(.init(source: repo.root, parent: repo.root, name: name)) { _ in } }
        }
        #expect(try String(contentsOfFile: repo.root + "/existing/precious", encoding: .utf8) == "keep")
        for source in ["-evil", "ext::sh command", "https://secret@host/repo", "ssh://user:password@host/repo", "https://host/repo\n"] {
            await #expect(throws: GitInspectionError.self) { try await cli.clone(.init(source: source, parent: repo.root, name: "new")) { _ in } }
            #expect(!FileManager.default.fileExists(atPath: repo.root + "/new"))
        }
        try repo.git(["config", "url.https://token@host/.insteadOf", "https://host/"])
        await #expect(throws: GitInspectionError.self) { try await cli.clone(.init(source: "https://host/repo", parent: repo.root, name: "new")) { _ in } }
        #expect(!FileManager.default.fileExists(atPath: repo.root + "/new"))
    }

    @Test func cloneFailureKeepsOwnedPartialFolderAndCancellationStopsChildren() async throws {
        let repo = try RepositoryFixture(); defer { repo.remove() }
        let script = repo.root + "/fake-git"
        let program = """
        #!/bin/sh
        case "$*" in
          *ls-remote*) echo '\(repo.root)'; exit 0;;
          *clone*)
            for last do :; done
            echo keep > "$last/partial"
            /bin/sleep 30 &
            echo $! > "$last/child.pid"
            echo started >&2
            wait;;
        esac
        """
        try program.write(toFile: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)
        let cli = GitCLI(executable: URL(fileURLWithPath: script))
        let task = Task { try await cli.clone(.init(source: repo.root, parent: repo.root, name: "partial-clone")) { _ in } }
        let pidFile = repo.root + "/partial-clone/child.pid"
        let deadline = ContinuousClock.now + .seconds(5)
        while !FileManager.default.fileExists(atPath: pidFile), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let pid = try #require(Int32(try String(contentsOfFile: pidFile, encoding: .utf8).trimmingCharacters(in: .newlines)))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        let end = ContinuousClock.now + .seconds(2)
        while kill(pid, 0) == 0, ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(10)) }
        #expect(kill(pid, 0) != 0)
        #expect(try String(contentsOfFile: repo.root + "/partial-clone/partial", encoding: .utf8) == "keep\n")
        await #expect(throws: GitInspectionError.self) { try await GitCLI().clone(.init(source: repo.root + "/missing", parent: repo.root, name: "failed")) { _ in } }
        #expect(FileManager.default.fileExists(atPath: repo.root + "/failed"))
    }
}
