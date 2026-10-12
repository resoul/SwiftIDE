import Foundation
import IDEApplication
import Testing
@testable import GitInfrastructure

struct GitOperationRecoveryTests {
    let cli = GitCLI()

    private func fixture() throws -> RepositoryFixture {
        let repo = try RepositoryFixture()
        try repo.write("a", "base\n")
        try repo.git(["add", "."])
        try repo.git(["commit", "-m", "Base"])
        try repo.git(["switch", "-c", "incoming"])
        try repo.write("a", "incoming\n")
        try repo.git(["commit", "-am", "Incoming"])
        try repo.git(["switch", "main"])
        try repo.write("a", "local\n")
        try repo.git(["commit", "-am", "Local"])

        return repo
    }

    @Test func cherryPickAndAmCanContinueSkipOrAbortTheirNativePausedState() async throws {
        for kind in [GitIntegrationKind.cherryPick, .am] {
            for operation in ["continue", "skip", "abort"] {
                let repo = try fixture()
                defer { repo.remove() }
                let original = try repo.git(["rev-parse", "HEAD"])
                if kind == .am {
                    let patch = try repo.git(["format-patch", "-1", "--stdout", "incoming"])
                    await #expect(throws: GitInspectionError.self) {
                        _ = try await cli.run(["am", "--3way"], at: repo.root, input: patch)
                    }
                } else {
                    #expect(throws: (any Error).self) { _ = try repo.git(["cherry-pick", "incoming"]) }
                }

                var snapshot = try await cli.snapshot(at: repo.root)
                let state = try #require(snapshot.integration)
                #expect(state.kind == kind && state.kind.supportsSkip)
                if operation == "continue" {
                    try repo.write("a", "resolved\n")
                    try repo.git(["add", "a"])
                    snapshot = try await cli.snapshot(at: repo.root)
                    try await cli.perform(.continueIntegration(state, ""), expected: snapshot) { _ in }
                    #expect(try repo.git(["show", "HEAD:a"]) == Data("resolved\n".utf8))
                } else {
                    let action: GitAction = operation == "skip" ? .skipRebase(state) : .abortIntegration(state)
                    try await cli.perform(action, expected: snapshot) { _ in }
                    #expect(try repo.git(["rev-parse", "HEAD"]) == original)
                    #expect(try repo.git(["show", "HEAD:a"]) == Data("local\n".utf8))
                }

                #expect(try await cli.snapshot(at: repo.root).integration == nil)
            }
        }
    }

    @Test func revertRecoveryAndMetadataChangesAreReviewed() async throws {
        for operation in ["continue", "skip", "abort"] {
            let repo = try fixture()
            defer { repo.remove() }
            try repo.git(["switch", "incoming"])
            let commit = String(decoding: try repo.git(["rev-parse", "HEAD"]), as: UTF8.self)
                .trimmingCharacters(in: .newlines)
            try repo.write("a", "later\n")
            try repo.git(["commit", "-am", "Later"])
            let original = try repo.git(["rev-parse", "HEAD"])
            #expect(throws: (any Error).self) { _ = try repo.git(["revert", "--no-edit", commit]) }
            var snapshot = try await cli.snapshot(at: repo.root)
            var state = try #require(snapshot.integration)
            #expect(state.kind == .revert)
            let oldState = state
            try repo.write(".git/MERGE_MSG", "Edited revert message\n")
            snapshot = try await cli.snapshot(at: repo.root)
            state = try #require(snapshot.integration)
            #expect(state.token != oldState.token)
            await #expect(throws: GitInspectionError.self) {
                try await cli.perform(.abortIntegration(oldState), expected: snapshot) { _ in }
            }
            if operation == "continue" {
                try repo.write("a", "resolved revert\n")
                try repo.git(["add", "a"])
                snapshot = try await cli.snapshot(at: repo.root)
                try await cli.perform(.continueIntegration(state, ""), expected: snapshot) { _ in }
                #expect(try repo.git(["show", "HEAD:a"]) == Data("resolved revert\n".utf8))
            } else {
                try await cli.perform(
                    operation == "skip" ? .skipRebase(state) : .abortIntegration(state),
                    expected: snapshot
                ) { _ in }
                #expect(try repo.git(["rev-parse", "HEAD"]) == original)
            }

            #expect(try await cli.snapshot(at: repo.root).integration == nil)
        }
    }
}
