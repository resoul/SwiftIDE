import Foundation
import Testing
import IDEApplication
@testable import GitInfrastructure

struct GitConflictIntegrationTests {
    private func divergent(_ path: String = "a.txt", binary: Bool = false) throws -> RepositoryFixture {
        let repo = try RepositoryFixture()
        try repo.write(path, binary ? "base\0blob" : "base\n"); try repo.git(["add", "."]); try repo.git(["commit", "-m", "Base"])
        try repo.git(["switch", "-c", "incoming"])
        try repo.write(path, binary ? "incoming\0blob" : "incoming\n"); try repo.git(["commit", "-am", "Incoming"])
        try repo.git(["switch", "main"])
        try repo.write(path, binary ? "local\0blob" : "local\n"); try repo.git(["commit", "-am", "Local"])

        return repo
    }
    private func start(_ kind: GitIntegrationKind, cli: GitCLI, repo: RepositoryFixture) async throws {
        let snapshot = try await cli.snapshot(at: repo.root), target = try #require(snapshot.branches.first { $0.name == "incoming" })
        try await cli.perform(.integrate(.init(repository: snapshot.repository, kind: kind, head: try #require(snapshot.head), branch: "main", target: target)), expected: snapshot) { _ in }
    }
    @Test func realMergeStagesCustomMarkersResolveAndContinueWithExplicitMessage() async throws {
        let repo = try divergent(":odd,\tname.txt"), cli = GitCLI(); defer { repo.remove() }
        try repo.write(".gitattributes", "* conflict-marker-size=11\n"); try repo.git(["add", ".gitattributes"]); try repo.git(["commit", "-m", "Markers"])
        await #expect(throws: GitInspectionError.self) { try await start(.merge, cli: cli, repo: repo) }
        var snapshot = try await cli.snapshot(at: repo.root)
        let operation = try #require(snapshot.integration), conflict = try await cli.conflict(in: snapshot, path: ":odd,\tname.txt")
        #expect(operation.kind == .merge && conflict.markerSize == 11)
        #expect(conflict.sides.map(\.stage) == [1, 2, 3])
        #expect(conflict.sides[0].text == "base\n" && conflict.sides[1].text == "local\n" && conflict.sides[2].text == "incoming\n")
        await #expect(throws: GitInspectionError.self) { try await cli.perform(.resolveConflict(conflict, .workingFile), expected: snapshot) { _ in } }
        await #expect(throws: GitInspectionError.self) { try await cli.perform(.stage(try #require(snapshot.changes.first { $0.decoration.isConflict })), expected: snapshot) { _ in } }
        try repo.write(":odd,\tname.txt", "reviewed result\n")
        snapshot = try await cli.snapshot(at: repo.root)
        try await cli.perform(.resolveConflict(conflict, .workingFile), expected: snapshot) { _ in }
        snapshot = try await cli.snapshot(at: repo.root)
        #expect(snapshot.integration == operation && !snapshot.changes.contains { $0.decoration.isConflict })
        try await cli.perform(.continueIntegration(operation, "Merge reviewed result"), expected: snapshot) { _ in }
        let done = try await cli.snapshot(at: repo.root)
        #expect(done.integration == nil && done.changes.isEmpty)
        #expect(String(decoding: try repo.git(["log", "-1", "--format=%P"]), as: UTF8.self).split(separator: " ").count == 2)
        #expect(try repo.git(["show", "HEAD::odd,\tname.txt"]) == Data("reviewed result\n".utf8))
    }
    @Test func missingStagesDeleteAndBinaryRestoreAreExplicitAndStaleIndexRefuses() async throws {
        let repo = try divergent(), cli = GitCLI(); defer { repo.remove() }
        try repo.git(["rm", "a.txt"]); try repo.git(["commit", "-m", "Delete local"])
        await #expect(throws: GitInspectionError.self) { try await start(.merge, cli: cli, repo: repo) }
        var snapshot = try await cli.snapshot(at: repo.root)
        let data = try await cli.conflict(in: snapshot, path: "a.txt")
        #expect(data.sides.first { $0.stage == 2 } == nil && data.sides.first { $0.stage == 3 }?.text == "incoming\n")
        try await cli.perform(.resolveConflict(data, .delete), expected: snapshot) { _ in }
        snapshot = try await cli.snapshot(at: repo.root)
        #expect(!FileManager.default.fileExists(atPath: repo.root + "/a.txt") && !snapshot.changes.contains { $0.decoration.isConflict })
        let binary = try divergent("b.bin", binary: true); defer { binary.remove() }
        await #expect(throws: GitInspectionError.self) { try await start(.merge, cli: cli, repo: binary) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: binary.root + "/b.bin")
        var bytes = try await cli.snapshot(at: binary.root)
        let conflict = try await cli.conflict(in: bytes, path: "b.bin")
        #expect(conflict.workingText == nil && conflict.sides.allSatisfy { $0.text == nil })
        try await cli.perform(.resolveConflict(conflict, .restoreStage(3)), expected: bytes) { _ in }
        #expect(try Data(contentsOf: URL(fileURLWithPath: binary.root + "/b.bin")) == Data("incoming\0blob".utf8))
        #expect(try FileManager.default.attributesOfItem(atPath: binary.root + "/b.bin")[.posixPermissions] as? Int == 0o600)
        bytes = try await cli.snapshot(at: binary.root)
        #expect(bytes.changes.contains { $0.decoration.isConflict }, "Taking a side is not resolving/staging it")
        try await cli.perform(.resolveConflict(conflict, .workingFile), expected: bytes) { _ in }
        bytes = try await cli.snapshot(at: binary.root)
        await #expect(throws: GitInspectionError.self) { try await cli.perform(.resolveConflict(conflict, .delete), expected: bytes) { _ in } }
        #expect(FileManager.default.fileExists(atPath: binary.root + "/b.bin"))
    }
    @Test func staleOperationSymlinkAndChangedDiskCannotDeleteOrRestore() async throws {
        let repo = try divergent(), outside = try RepositoryFixture(), cli = GitCLI(); defer { repo.remove(); outside.remove() }
        await #expect(throws: GitInspectionError.self) { try await start(.merge, cli: cli, repo: repo) }
        var snapshot = try await cli.snapshot(at: repo.root)
        let conflict = try await cli.conflict(in: snapshot, path: "a.txt"), status = try #require(snapshot.integration)
        try repo.write("a.txt", "new external edit\n"); snapshot = try await cli.snapshot(at: repo.root)
        for resolution in [GitConflictResolution.delete, .restoreStage(3)] {
            await #expect(throws: GitInspectionError.self) { try await cli.perform(.resolveConflict(conflict, resolution), expected: snapshot) { _ in } }
        }
        #expect(try String(contentsOfFile: repo.root + "/a.txt", encoding: .utf8) == "new external edit\n")
        try repo.write(".git/MERGE_MSG", "Different operation message\n"); snapshot = try await cli.snapshot(at: repo.root)
        await #expect(throws: GitInspectionError.self) { try await cli.perform(.abortIntegration(status), expected: snapshot) { _ in } }
        try outside.write("safe", "do not touch")
        try FileManager.default.removeItem(atPath: repo.root + "/a.txt")
        try FileManager.default.createSymbolicLink(atPath: repo.root + "/a.txt", withDestinationPath: outside.root + "/safe")
        snapshot = try await cli.snapshot(at: repo.root)
        await #expect(throws: GitInspectionError.self) { try await cli.conflict(in: snapshot, path: "a.txt") }
        await #expect(throws: GitInspectionError.self) { try await cli.perform(.resolveConflict(conflict, .workingFile), expected: snapshot) { _ in } }
        #expect(try String(contentsOfFile: outside.root + "/safe", encoding: .utf8) == "do not touch")
    }
    @Test func mergeWithoutConflictsStopsForMessageAndAbortRestoresOriginalTip() async throws {
        let repo = try RepositoryFixture(), cli = GitCLI(); defer { repo.remove() }
        try repo.write("a", "base"); try repo.git(["add", "."]); try repo.git(["commit", "-m", "Base"])
        let original = try repo.git(["rev-parse", "HEAD"])
        try repo.git(["switch", "-c", "incoming"]); try repo.write("b", "new"); try repo.git(["add", "."]); try repo.git(["commit", "-m", "Incoming"]); try repo.git(["switch", "main"])
        try repo.git(["config", "branch.main.mergeOptions", "--commit --ff-only --autostash"])
        try await start(.merge, cli: cli, repo: repo)
        var snapshot = try await cli.snapshot(at: repo.root)
        #expect(try repo.git(["rev-parse", "HEAD"]) == original && snapshot.integration?.kind == .merge)
        let active = try #require(snapshot.integration)
        await #expect(throws: GitInspectionError.self) { try await cli.perform(.continueIntegration(active, ""), expected: snapshot) { _ in } }
        try await cli.perform(.abortIntegration(active), expected: snapshot) { _ in }
        snapshot = try await cli.snapshot(at: repo.root)
        #expect(snapshot.integration == nil && snapshot.changes.isEmpty && !FileManager.default.fileExists(atPath: repo.root + "/b"))
        #expect(try repo.git(["rev-parse", "HEAD"]) == original)
    }
    @Test func rebaseRoleLabelsResolutionContinueAndAbortRecoverOriginalHistory() async throws {
        let repo = try divergent(), cli = GitCLI(); defer { repo.remove() }
        let original = try repo.git(["rev-parse", "HEAD"])
        await #expect(throws: GitInspectionError.self) { try await start(.rebase, cli: cli, repo: repo) }
        var snapshot = try await cli.snapshot(at: repo.root)
        let active = try #require(snapshot.integration), data = try await cli.conflict(in: snapshot, path: "a.txt")
        #expect(active.kind == .rebase && snapshot.branch == nil)
        #expect(data.sides.first { $0.stage == 2 }?.text == "incoming\n" && data.sides.first { $0.stage == 3 }?.text == "local\n")
        try await cli.perform(.abortIntegration(active), expected: snapshot) { _ in }
        #expect(try repo.git(["rev-parse", "HEAD"]) == original)
        await #expect(throws: GitInspectionError.self) { try await start(.rebase, cli: cli, repo: repo) }
        snapshot = try await cli.snapshot(at: repo.root)
        let second = try #require(snapshot.integration), conflict = try await cli.conflict(in: snapshot, path: "a.txt")
        try repo.write("a.txt", "resolved\n"); snapshot = try await cli.snapshot(at: repo.root)
        try await cli.perform(.resolveConflict(conflict, .workingFile), expected: snapshot) { _ in }
        snapshot = try await cli.snapshot(at: repo.root)
        try await cli.perform(.continueIntegration(second, ""), expected: snapshot) { _ in }
        snapshot = try await cli.snapshot(at: repo.root)
        #expect(snapshot.integration == nil && snapshot.branch == "main" && snapshot.changes.isEmpty)
        #expect(try repo.git(["rev-parse", "HEAD"]) != original)
        #expect(try repo.git(["log", "-1", "--format=%s"]) == Data("Local\n".utf8))
    }
    @Test func explicitSkipDropsOnlyCurrentCommitAndIgnoredReplayPathIsProtected() async throws {
        let repo = try divergent(), cli = GitCLI(); defer { repo.remove() }
        await #expect(throws: GitInspectionError.self) { try await start(.rebase, cli: cli, repo: repo) }
        var snapshot = try await cli.snapshot(at: repo.root)
        try await cli.perform(.skipRebase(try #require(snapshot.integration)), expected: snapshot) { _ in }
        snapshot = try await cli.snapshot(at: repo.root)
        #expect(snapshot.integration == nil && snapshot.branch == "main")
        #expect(try repo.git(["show", "HEAD:a.txt"]) == Data("incoming\n".utf8))
        let protected = try RepositoryFixture(); defer { protected.remove() }
        try protected.write("base", "base"); try protected.git(["add", "."]); try protected.git(["commit", "-m", "Base"])
        try protected.git(["branch", "incoming"])
        try protected.write("transient", "committed briefly"); try protected.git(["add", "."]); try protected.git(["commit", "-m", "Add"])
        try protected.git(["rm", "transient"]); try protected.git(["commit", "-m", "Delete"])
        try protected.git(["switch", "incoming"]); try protected.write("other", "remote"); try protected.git(["add", "."]); try protected.git(["commit", "-m", "Remote"]); try protected.git(["switch", "main"])
        try protected.write(".git/info/exclude", "transient\n"); try protected.write("transient", "keep ignored bytes")
        let before = try protected.git(["rev-parse", "HEAD"])
        await #expect(throws: GitInspectionError.self) { try await start(.rebase, cli: cli, repo: protected) }
        #expect(try protected.git(["rev-parse", "HEAD"]) == before && !FileManager.default.fileExists(atPath: protected.root + "/.git/rebase-merge"))
        #expect(try String(contentsOfFile: protected.root + "/transient", encoding: .utf8) == "keep ignored bytes")
    }
    @Test func cleanRebaseKeepsOtherBranchRefsAndEmptyReplayRequiresExplicitSkip() async throws {
        let repo = try RepositoryFixture(), cli = GitCLI(); defer { repo.remove() }
        try repo.write("a", "base"); try repo.git(["add", "."]); try repo.git(["commit", "-m", "Base"])
        try repo.git(["branch", "incoming"])
        try repo.write("local", "local"); try repo.git(["add", "."]); try repo.git(["commit", "-m", "Local"])
        try repo.git(["branch", "keep-original"])
        let original = try repo.git(["rev-parse", "HEAD"])
        try repo.git(["switch", "incoming"]); try repo.write("other", "remote"); try repo.git(["add", "."]); try repo.git(["commit", "-m", "Remote"]); try repo.git(["switch", "main"])
        try repo.git(["config", "rebase.updateRefs", "true"]); try repo.git(["config", "rebase.autoStash", "true"])
        try await start(.rebase, cli: cli, repo: repo)
        var snapshot = try await cli.snapshot(at: repo.root)
        #expect(snapshot.integration == nil && snapshot.branch == "main" && snapshot.changes.isEmpty)
        #expect(try repo.git(["rev-parse", "HEAD"]) != original && repo.git(["rev-parse", "keep-original"]) == original)
        let empty = try RepositoryFixture(); defer { empty.remove() }
        try empty.write("a", "base"); try empty.git(["add", "."]); try empty.git(["commit", "-m", "Base"]); try empty.git(["branch", "incoming"])
        try empty.write("a", "same patch"); try empty.git(["commit", "-am", "Local duplicate"])
        try empty.git(["switch", "incoming"]); try empty.write("a", "same patch"); try empty.write("other", "remote"); try empty.git(["add", "."]); try empty.git(["commit", "-m", "Remote"]); try empty.git(["switch", "main"])
        await #expect(throws: GitInspectionError.self) { try await start(.rebase, cli: cli, repo: empty) }
        snapshot = try await cli.snapshot(at: empty.root)
        #expect(snapshot.integration?.kind == .rebase && !snapshot.changes.contains { $0.decoration.isConflict })
        let status = try #require(snapshot.integration)
        await #expect(throws: GitInspectionError.self) { try await cli.perform(.continueIntegration(status, ""), expected: snapshot) { _ in } }
        snapshot = try await cli.snapshot(at: empty.root)
        try await cli.perform(.skipRebase(try #require(snapshot.integration)), expected: snapshot) { _ in }
        #expect(try await cli.snapshot(at: empty.root).integration == nil)
    }
    @Test func cancelledPostCommitChildReleasesGateAndDoesNotRollBackCompletedMerge() async throws {
        let repo = try RepositoryFixture(), cli = GitCLI(); defer { repo.remove() }
        try repo.write("a", "base"); try repo.git(["add", "."]); try repo.git(["commit", "-m", "Base"])
        try repo.git(["switch", "-c", "incoming"]); try repo.write("b", "remote"); try repo.git(["add", "."]); try repo.git(["commit", "-m", "Remote"]); try repo.git(["switch", "main"])
        try await start(.merge, cli: cli, repo: repo)
        let snapshot = try await cli.snapshot(at: repo.root), status = try #require(snapshot.integration)
        try repo.write(".git/hooks/post-commit", "#!/bin/sh\n/bin/sleep 30 &\necho $! > '\(repo.root)/.git/child.pid'\nwait\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: repo.root + "/.git/hooks/post-commit")
        let action = GitAction.continueIntegration(status, "Merge fixture")
        let task = Task { try await cli.perform(action, expected: snapshot) { _ in } }; defer { task.cancel() }
        let deadline = ContinuousClock.now + .seconds(10)
        while !FileManager.default.fileExists(atPath: repo.root + "/.git/child.pid"), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let pid = try #require(Int32(try String(contentsOfFile: repo.root + "/.git/child.pid", encoding: .utf8).trimmingCharacters(in: .newlines)))
        await #expect(throws: GitInspectionError.failed("Another Git action is running for this repository")) { try await cli.perform(action, expected: snapshot) { _ in } }
        task.cancel(); await #expect(throws: CancellationError.self) { try await task.value }
        let end = ContinuousClock.now + .seconds(2)
        while kill(pid, 0) == 0, ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(10)) }
        #expect(kill(pid, 0) != 0)
        let current = try await cli.snapshot(at: repo.root)
        #expect(current.head != snapshot.head && FileManager.default.fileExists(atPath: repo.root + "/b"))
        try await cli.perform(.createBranch("after-cancel"), expected: current) { _ in }
    }

    @Test func resolutionStagesCapturedBytesAndRefusesMarkersIntroducedByCleanFilter() async throws {
        let repo = try divergent(), cli = GitCLI(); defer { repo.remove() }
        await #expect(throws: GitInspectionError.self) { try await start(.merge, cli: cli, repo: repo) }
        var snapshot = try await cli.snapshot(at: repo.root)
        let conflict = try await cli.conflict(in: snapshot, path: "a.txt")
        try repo.write("a.txt", "captured result\n")
        try repo.write(".git/info/attributes", "a.txt filter=fixture\n")
        try repo.write(".git/filter.sh", "#!/bin/sh\n/bin/cat\nprintf 'later disk edit\n' > a.txt\n")
        try repo.git(["config", "filter.fixture.clean", "/bin/sh .git/filter.sh"]); try repo.git(["config", "filter.fixture.required", "true"])
        snapshot = try await cli.snapshot(at: repo.root)
        try await cli.perform(.resolveConflict(conflict, .workingFile), expected: snapshot) { _ in }
        #expect(try repo.git(["show", ":a.txt"]) == Data("captured result\n".utf8))
        #expect(try String(contentsOfFile: repo.root + "/a.txt", encoding: .utf8) == "later disk edit\n")
        let bad = try divergent(), second = GitCLI(); defer { bad.remove() }
        await #expect(throws: GitInspectionError.self) { try await start(.merge, cli: second, repo: bad) }
        var other = try await second.snapshot(at: bad.root)
        let captured = try await second.conflict(in: other, path: "a.txt")
        try bad.write("a.txt", "resolved\n")
        try bad.write(".git/info/attributes", "a.txt filter=bad\n")
        try bad.write(".git/filter.sh", "#!/bin/sh\n/bin/cat >/dev/null\nprintf '<<<<<<< introduced by filter\n'\n")
        try bad.git(["config", "filter.bad.clean", "/bin/sh .git/filter.sh"]); try bad.git(["config", "filter.bad.required", "true"])
        other = try await second.snapshot(at: bad.root)
        await #expect(throws: GitInspectionError.self) { try await second.perform(.resolveConflict(captured, .workingFile), expected: other) { _ in } }
        #expect(try await second.snapshot(at: bad.root).changes.contains { $0.decoration.isConflict })
    }

}
