import Foundation
import IDEApplication
import Testing
@testable import GitInfrastructure

struct GitExtendedConflictTests {
    let cli = GitCLI()

    private func fixture() throws -> RepositoryFixture {
        let repo = try RepositoryFixture()
        try repo.write("a.txt", "base\n")
        try repo.git(["add", "."])
        try repo.git(["commit", "-m", "Base"])

        return repo
    }

    private func blob(_ text: String, repo: RepositoryFixture) async throws -> String {
        String(
            decoding: try await cli.run(["hash-object", "-w", "--stdin"], at: repo.root, input: Data(text.utf8)),
            as: UTF8.self
        )
        .trimmingCharacters(in: .newlines)
    }

    private func inject(_ path: String, mode: String, objects: [String], repo: RepositoryFixture) async throws {
        let zeros = String(repeating: "0", count: objects[0].count)
        let record = "0 " + zeros + "\t" + path + "\0" + objects.enumerated().map {
            mode + " " + $0.element + " \($0.offset + 1)\t" + path + "\0"
        }.joined()
        _ = try await cli.run(["update-index", "-z", "--index-info"], at: repo.root, input: Data(record.utf8))
    }

    @Test func symlinkRestorationAndResolutionNeverChangeTargetContents() async throws {
        let repo = try fixture()
        defer { repo.remove() }
        let outside = repo.root + "-outside", other = repo.root + "-other"
        defer {
            try? FileManager.default.removeItem(atPath: outside)
            try? FileManager.default.removeItem(atPath: other)
        }
        try "sentinel one".write(toFile: outside, atomically: true, encoding: .utf8)
        try "sentinel two".write(toFile: other, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: repo.root + "/link", withDestinationPath: outside)
        let objects = try await [blob("base-target", repo: repo), blob(outside, repo: repo), blob(other, repo: repo)]
        try await inject("link", mode: "120000", objects: objects, repo: repo)
        var snapshot = try await cli.snapshot(at: repo.root)
        var conflict = try await cli.conflict(in: snapshot, path: "link")
        #expect(conflict.workingKind == .symlink && conflict.workingText == nil && conflict.supportsResolution)
        try await cli.perform(.resolveConflict(conflict, .restoreStage(3)), expected: snapshot, output: { _ in })
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: repo.root + "/link") == other)
        snapshot = try await cli.snapshot(at: repo.root)
        conflict = try await cli.conflict(in: snapshot, path: "link")
        try await cli.perform(.resolveConflict(conflict, .workingFile), expected: snapshot, output: { _ in })
        #expect(try repo.git(["show", ":link"]) == Data(other.utf8))
        #expect(try String(contentsOfFile: outside, encoding: .utf8) == "sentinel one")
        #expect(try String(contentsOfFile: other, encoding: .utf8) == "sentinel two")
    }

    @Test func directoryIndexDeletionKeepsEveryNestedWorkingByte() async throws {
        let repo = try fixture()
        defer { repo.remove() }
        try repo.write("clash/keep.bin", "directory sentinel")
        let objects = try await [blob("base\n", repo: repo), blob("ours\n", repo: repo), blob("theirs\n", repo: repo)]
        try await inject("clash", mode: "100644", objects: objects, repo: repo)
        let snapshot = try await cli.snapshot(at: repo.root), conflict = try await cli.conflict(
            in: snapshot,
            path: "clash"
        )
        #expect(conflict.workingKind == .directory)
        await #expect(throws: GitInspectionError.self) {
            try await cli.perform(.resolveConflict(conflict, .delete), expected: snapshot, output: { _ in })
        }
        try await cli.perform(.resolveConflict(conflict, .indexDeleted), expected: snapshot, output: { _ in })
        #expect(try await cli.snapshot(at: repo.root).changes.allSatisfy { !$0.decoration.isConflict })
        #expect(try String(contentsOfFile: repo.root + "/clash/keep.bin", encoding: .utf8) == "directory sentinel")
    }

    @Test func submodulePointerChoiceKeepsNestedCheckoutAndDirtyFiles() async throws {
        let repo = try fixture(), nested = try fixture()
        defer {
            repo.remove()
            nested.remove()
        }
        let base = String(decoding: try nested.git(["rev-parse", "HEAD"]), as: UTF8.self)
            .trimmingCharacters(in: .newlines)
        try nested.git(["commit", "--allow-empty", "-m", "Ours"])
        let ours = String(decoding: try nested.git(["rev-parse", "HEAD"]), as: UTF8.self)
            .trimmingCharacters(in: .newlines)
        try nested.git(["commit", "--allow-empty", "-m", "Theirs"])
        let theirs = String(decoding: try nested.git(["rev-parse", "HEAD"]), as: UTF8.self)
            .trimmingCharacters(in: .newlines)
        try repo.git(["clone", nested.root, "module"])
        try repo.git(["-C", "module", "checkout", ours])
        try repo.write("module/dirty.txt", "keep nested edits")
        try await inject("module", mode: "160000", objects: [base, ours, theirs], repo: repo)
        let snapshot = try await cli.snapshot(at: repo.root), conflict = try await cli.conflict(
            in: snapshot,
            path: "module"
        )
        #expect(conflict.workingKind == .submodule)
        try await cli.perform(.resolveConflict(conflict, .indexStage(3)), expected: snapshot, output: { _ in })
        #expect(String(decoding: try repo.git(["ls-files", "--stage", "module"]), as: UTF8.self).contains(theirs))
        #expect(String(decoding: try repo.git(["-C", "module", "rev-parse", "HEAD"]), as: UTF8.self)
            .trimmingCharacters(in: .newlines) == ours)
        #expect(try String(contentsOfFile: repo.root + "/module/dirty.txt", encoding: .utf8) == "keep nested edits")
    }

    @Test func literalMarkerOverrideIsExplicitButCompleteRegionsStillFail() async throws {
        let repo = try fixture()
        defer { repo.remove() }
        let objects = try await [blob("base\n", repo: repo), blob("ours\n", repo: repo), blob("theirs\n", repo: repo)]
        try await inject("a.txt", mode: "100644", objects: objects, repo: repo)
        try repo.write("a.txt", "======= intended separator\n")
        var snapshot = try await cli.snapshot(at: repo.root), conflict = try await cli.conflict(
            in: snapshot,
            path: "a.txt"
        )
        await #expect(throws: GitInspectionError.self) {
            try await cli.perform(.resolveConflict(conflict, .workingFile), expected: snapshot, output: { _ in })
        }
        try await cli.perform(
            .resolveConflict(conflict, .workingFileAllowingLiteralMarkers),
            expected: snapshot,
            output: { _ in }
        )
        #expect(try repo.git(["show", ":a.txt"]) == Data("======= intended separator\n".utf8))
        try await inject("a.txt", mode: "100644", objects: objects, repo: repo)
        try repo.write("a.txt", "<<<<<<< ours\none\n=======\ntwo\n>>>>>>> theirs\n")
        snapshot = try await cli.snapshot(at: repo.root)
        conflict = try await cli.conflict(in: snapshot, path: "a.txt")
        await #expect(throws: GitInspectionError.self) {
            try await cli.perform(
                .resolveConflict(conflict, .workingFileAllowingLiteralMarkers),
                expected: snapshot,
                output: { _ in }
            )
        }
    }
}
