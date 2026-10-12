import Foundation
import IDEApplication
import Testing
@testable import GitInfrastructure

struct GitPartialStagingTests {
    let cli = GitCLI()

    private func fixture(_ value: String = "a\nb\nc\nd\ne\nf\ng\nh\ni\nj\nk\nl\n") throws -> RepositoryFixture {
        let repo = try RepositoryFixture()
        try repo.write("a.txt", value)
        try repo.git(["add", "."])
        try repo.git(["commit", "-m", "Base"])

        return repo
    }

    private func preview(_ repo: RepositoryFixture, path: String = "a.txt", unstage: Bool = false) async throws
        -> (GitSnapshot, GitPartialDiff) {
        let snapshot = try await cli.snapshot(at: repo.root)
        let change = try #require(snapshot.changes.first { $0.path == path })
        let comparison: GitComparison = unstage
            ? .index(change)
            : change.decoration.isUntracked ? .untracked(change) : .worktree(change)

        return (snapshot, try await cli.partialDiff(in: snapshot, comparison: comparison))
    }

    @Test func stageOneBlockPreservesOtherIndexAndWorktreeChangesAndUnstageOnlyTheChosenLines() async throws {
        let repo = try fixture()
        defer { repo.remove() }
        try repo.write("a.txt", "A\nb\nc\nd\ne\nf\ng\nh\ni\nj\nk\nL\n")
        try repo.write("other.txt", "already staged\n")
        try repo.git(["add", "other.txt"])
        let disk = try Data(contentsOf: URL(fileURLWithPath: repo.root + "/a.txt"))
        let (snapshot, diff) = try await preview(repo)
        try #require(diff.hunks.count == 2)
        try await cli.perform(
            .partial(.init(diff: diff, lines: diff.hunks[0].changedIDs)),
            expected: snapshot,
            output: { _ in }
        )
        #expect(try repo.git(["show", ":a.txt"]) == Data("A\nb\nc\nd\ne\nf\ng\nh\ni\nj\nk\nl\n".utf8))
        #expect(try repo.git(["show", ":other.txt"]) == Data("already staged\n".utf8))
        let (staged, undo) = try await preview(repo, unstage: true)
        let removed = try #require(undo.hunks.flatMap(\.lines).first { $0.kind == .deletion })
        try await cli.perform(.partial(.init(diff: undo, lines: [removed.id])), expected: staged, output: { _ in })
        #expect(try repo.git(["show", ":a.txt"]) == Data("a\nA\nb\nc\nd\ne\nf\ng\nh\ni\nj\nk\nl\n".utf8))
        #expect(try Data(contentsOf: URL(fileURLWithPath: repo.root + "/a.txt")) == disk)
    }

    @Test func newFileAndUnbornIndexSupportPartialLinesIncludingLiteralNewlinePaths() async throws {
        let repo = try RepositoryFixture()
        defer { repo.remove() }
        let path = ":(glob)* space\nfile.txt"
        try repo.write(path, "first\nsecond\nthird")
        let (snapshot, diff) = try await preview(repo, path: path)
        let first = try #require(diff.hunks.first?.lines.first)
        try await cli.perform(.partial(.init(diff: diff, lines: [first.id])), expected: snapshot, output: { _ in })
        #expect(try repo.git(["show", ":" + path]) == Data("first\n".utf8))
        let (staged, undo) = try await preview(repo, path: path, unstage: true)
        try await cli.perform(.partial(.init(diff: undo, lines: undo.changedIDs)), expected: staged, output: { _ in })
        #expect(try await cli.snapshot(at: repo.root).changes.first { $0.path == path }?.decoration.isUntracked == true)
        #expect(try String(contentsOfFile: repo.root + "/" + path, encoding: .utf8) == "first\nsecond\nthird")
        #expect(!FileManager.default.fileExists(atPath: snapshot.repository.gitDirectory + "/index.lock"))
    }

    @Test func crlfBomAndNoFinalNewlineBytesSurviveSelectedReplacements() async throws {
        let original = "\u{feff}a\r\nb\r\nc"
        let repo = try RepositoryFixture()
        defer { repo.remove() }
        try repo.git(["config", "core.autocrlf", "false"])
        try repo.write("a.txt", original)
        try repo.git(["add", "."])
        try repo.git(["commit", "-m", "CRLF base"])
        try repo.write("a.txt", "\u{feff}A\r\nb\r\nC")
        let (snapshot, diff) = try await preview(repo)
        let chosen = Set(diff.hunks.flatMap(\.lines).filter { $0.text.contains("\u{feff}") }.map(\.id))
        try await cli.perform(.partial(.init(diff: diff, lines: chosen)), expected: snapshot, output: { _ in })
        #expect(try repo.git(["show", ":a.txt"]) == Data("\u{feff}A\r\nb\r\nc".utf8))
        let (next, rest) = try await preview(repo)
        try await cli.perform(.partial(.init(diff: rest, lines: rest.changedIDs)), expected: next, output: { _ in })
        #expect(try repo.git(["show", ":a.txt"]) == Data("\u{feff}A\r\nb\r\nC".utf8))
    }

    @Test func partialDeletionKeepsTheRestAndUnstageDeletionRestoresOnlyChosenLines() async throws {
        let repo = try fixture("one\ntwo\nthree\n")
        defer { repo.remove() }
        try FileManager.default.removeItem(atPath: repo.root + "/a.txt")
        var (snapshot, diff) = try await preview(repo)
        let first = try #require(diff.hunks.first?.lines.first)
        try await cli.perform(.partial(.init(diff: diff, lines: [first.id])), expected: snapshot, output: { _ in })
        #expect(try repo.git(["show", ":a.txt"]) == Data("two\nthree\n".utf8))
        (snapshot, diff) = try await preview(repo)
        try await cli.perform(.partial(.init(diff: diff, lines: diff.changedIDs)), expected: snapshot, output: { _ in })
        (snapshot, diff) = try await preview(repo, unstage: true)
        let two = try #require(diff.hunks.flatMap(\.lines).first { $0.text == "two" })
        try await cli.perform(.partial(.init(diff: diff, lines: [two.id])), expected: snapshot, output: { _ in })
        #expect(try repo.git(["show", ":a.txt"]) == Data("two\n".utf8))
        #expect(!FileManager.default.fileExists(atPath: repo.root + "/a.txt"))
    }

    @Test func staleTextIsRejectedEvenWhenPorcelainStatusHasNotChangedAndNativeLocksArePreserved() async throws {
        let repo = try fixture("base\n")
        defer { repo.remove() }
        try repo.write("a.txt", "first\n")
        let (snapshot, diff) = try await preview(repo)
        let originalIndex = try Data(contentsOf: URL(fileURLWithPath: snapshot.repository.gitDirectory + "/index"))
        try repo.write("a.txt", "later\n")
        await #expect(throws: GitInspectionError.self) {
            try await cli.perform(
                .partial(.init(diff: diff, lines: diff.changedIDs)),
                expected: snapshot,
                output: { _ in }
            )
        }
        #expect(try Data(contentsOf: URL(fileURLWithPath: snapshot.repository.gitDirectory + "/index")) ==
            originalIndex)
        let lock = snapshot.repository.gitDirectory + "/index.lock"
        try Data("other owner".utf8).write(to: URL(fileURLWithPath: lock))
        let (fresh, current) = try await preview(repo)
        await #expect(throws: GitInspectionError.self) {
            try await cli.perform(
                .partial(.init(diff: current, lines: current.changedIDs)),
                expected: fresh,
                output: { _ in }
            )
        }
        #expect(try Data(contentsOf: URL(fileURLWithPath: lock)) == Data("other owner".utf8))
    }

    @Test func binaryEncodingFiltersAndModeOnlyChangesAreExplicitlyUnavailable() async throws {
        let repo = try fixture("base\n")
        defer { repo.remove() }
        try Data([0, 1, 2]).write(to: URL(fileURLWithPath: repo.root + "/a.txt"))
        await #expect(throws: GitInspectionError.self) { _ = try await preview(repo) }
        try repo.write("a.txt", "new\n")
        try repo.write(".gitattributes", "a.txt filter=custom\n")
        await #expect(throws: GitInspectionError.self) { _ = try await preview(repo) }
        try repo.write(".gitattributes", "")
        try repo.write("a.txt", "base\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: repo.root + "/a.txt")
        await #expect(throws: GitInspectionError.self) { _ = try await preview(repo) }
    }

    @Test func untrackedSelectionUsesNativeCrlfNormalizationWithoutTouchingDisk() async throws {
        let repo = try RepositoryFixture()
        defer { repo.remove() }
        try repo.git(["config", "core.autocrlf", "input"])
        try repo.write("a.txt", "one\r\ntwo\r\n")
        let (snapshot, diff) = try await preview(repo)
        let first = try #require(diff.hunks.first?.lines.first)
        try await cli.perform(.partial(.init(diff: diff, lines: [first.id])), expected: snapshot, output: { _ in })
        #expect(try repo.git(["show", ":a.txt"]) == Data("one\n".utf8))
        #expect(try String(contentsOfFile: repo.root + "/a.txt", encoding: .utf8) == "one\r\ntwo\r\n")
    }
}

extension GitPartialStagingTests {
    @Test func nativeSHA256SplitIndexAndPermissionsSurvivePartialPublication() async throws {
        let repo = try RepositoryFixture()
        defer { repo.remove() }
        try FileManager.default.removeItem(atPath: repo.root + "/.git")
        try repo.git(["init", "--object-format=sha256", "-b", "main"])
        try repo.git(["config", "user.name", "Fixture"])
        try repo.git(["config", "user.email", "fixture@example.test"])
        try repo.git(["config", "commit.gpgsign", "false"])
        try repo.write("a.txt", "one\ntwo\n")
        try repo.git(["add", "."])
        try repo.git(["commit", "-m", "Base"])
        try repo.git(["update-index", "--split-index"])
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: repo.root + "/.git/index")
        try repo.write("a.txt", "ONE\ntwo\n")
        let (snapshot, diff) = try await preview(repo)
        #expect(snapshot.head?.count == 64)
        try await cli.perform(.partial(.init(diff: diff, lines: diff.hunks[0].changedIDs)), expected: snapshot) { _ in }
        #expect(try repo.git(["show", ":a.txt"]) == Data("ONE\ntwo\n".utf8))
        #expect(try FileManager.default
            .attributesOfItem(atPath: repo.root + "/.git/index")[.posixPermissions] as? Int == 0o640)
    }

    @Test func replacingOwnedLockCannotPublishOrRemoveTheForeignLock() async throws {
        let repo = try fixture()
        defer { repo.remove() }
        let repository = try await cli.repository(at: repo.root)
        let original = try Data(contentsOf: URL(fileURLWithPath: repo.root + "/.git/index"))
        let transaction = try GitIndexTransaction(repository: repository)
        try original.write(to: transaction.candidate)
        try FileManager.default.removeItem(atPath: repo.root + "/.git/index.lock")
        try repo.write(".git/index.lock", "foreign lock")
        #expect(throws: GitInspectionError.self) { try transaction.publish() }
        transaction.close()
        #expect(try String(contentsOfFile: repo.root + "/.git/index.lock", encoding: .utf8) == "foreign lock")
        #expect(try Data(contentsOf: URL(fileURLWithPath: repo.root + "/.git/index")) == original)
    }
}
