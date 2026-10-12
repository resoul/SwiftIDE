import Foundation
import IDEApplication
import Testing
@testable import GitInfrastructure

struct GitConflictGroupTests {
    let cli = GitCLI()

    private func fixture() throws -> RepositoryFixture {
        let repo = try RepositoryFixture()
        try repo.write("original space\nfile", "one\ntwo\nthree\nfour\n")
        try repo.git(["add", "."])
        try repo.git(["commit", "-m", "Base"])
        try repo.git(["switch", "-c", "incoming"])
        try repo.git(["mv", "original space\nfile", "theirs"])
        try repo.git(["commit", "-am", "Theirs rename"])
        try repo.git(["switch", "main"])
        try repo.git(["mv", "original space\nfile", "ours"])
        try repo.git(["commit", "-am", "Ours rename"])
        #expect(throws: (any Error).self) { _ = try repo.git(["merge", "--no-commit", "incoming"]) }

        return repo
    }

    @Test func realRenameRenameGroupChoosesEachSideAtomicallyKeepingDisk() async throws {
        for stage in 1...3 {
            let repo = try fixture()
            defer { repo.remove() }
            let snapshot = try await cli.snapshot(at: repo.root)
            let group = try #require(await cli.conflictGroup(in: snapshot, path: "ours"))
            #expect(group.paths == ["original space\nfile", "ours", "theirs"])
            let copies = try group.paths.filter { FileManager.default.fileExists(atPath: repo.root + "/" + $0) }
                .map { ($0, try Data(contentsOf: URL(fileURLWithPath: repo.root + "/" + $0))) }
            try await cli.perform(.resolveConflictGroup(group, stage), expected: snapshot) { _ in }
            #expect(try await cli.snapshot(at: repo.root).changes.allSatisfy { !$0.decoration.isConflict })
            let expectedPath = stage == 1 ? "original space\nfile" : stage == 2 ? "ours" : "theirs"
            #expect(try repo.git(["show", ":" + expectedPath]) == Data("one\ntwo\nthree\nfour\n".utf8))
            for (path, bytes) in copies {
                #expect(try Data(contentsOf: URL(fileURLWithPath: repo.root + "/" + path)) == bytes)
            }
        }
    }

    @Test func foreignLockAndChangedStagesDoNotPublishRelatedResolution() async throws {
        let repo = try fixture()
        defer { repo.remove() }
        var snapshot = try await cli.snapshot(at: repo.root)
        let group = try #require(await cli.conflictGroup(in: snapshot, path: "theirs"))
        let original = try Data(contentsOf: URL(fileURLWithPath: repo.root + "/.git/index"))
        try repo.write(".git/index.lock", "external writer")
        await #expect(throws: GitInspectionError.self) {
            try await cli.perform(.resolveConflictGroup(group, 2), expected: snapshot) { _ in }
        }
        #expect(try Data(contentsOf: URL(fileURLWithPath: repo.root + "/.git/index")) == original)
        #expect(try String(contentsOfFile: repo.root + "/.git/index.lock", encoding: .utf8) == "external writer")
        try FileManager.default.removeItem(atPath: repo.root + "/.git/index.lock")
        try repo.git(["add", "theirs"])
        snapshot = try await cli.snapshot(at: repo.root)
        await #expect(throws: GitInspectionError.self) {
            try await cli.perform(.resolveConflictGroup(group, 2), expected: snapshot) { _ in }
        }
    }
}
