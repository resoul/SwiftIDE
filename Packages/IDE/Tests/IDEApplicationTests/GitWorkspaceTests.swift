import Foundation
import Testing
@testable import IDEApplication

@Suite(.serialized) @MainActor
struct GitWorkspaceTests {
    private let repository = GitRepository(root: "/repo", gitDirectory: "/repo/.git", commonDirectory: "/repo/.git")

    private func settle(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        try #require(predicate())
    }

    @Test func staleRefreshAndFailureCannotReplaceCurrentIdentifiedSnapshot() async throws {
        let service = ControlledGit(), model = GitWorkspace(root: "/repo", service: service)
        defer { model.stop() }
        model.refresh()
        try await service.waitForSnapshots(1)
        model.refresh()
        try await service.waitForSnapshots(2)
        let current = GitSnapshot(
            repository: repository,
            branch: "current",
            head: nil,
            changes: [.init(path: "file", decoration: .init(index: "A"))]
        )
        await service.replySnapshot(1, .success(current))
        try await settle { model.state == .ready }
        await service.replySnapshot(0, .success(.init(repository: repository, branch: "old", head: nil, changes: [])))
        try await Task.sleep(for: .milliseconds(20))
        #expect(model.snapshot?.branch == "current")
        model.refresh()
        try await service.waitForSnapshots(3)
        await service.replySnapshot(2, .failure(GitInspectionError.failed("permission denied")))
        try await settle { model.state == .failed("permission denied") }
        #expect(model.snapshot?.changes.count == 1 && model.explanation.contains("previous snapshot"))
    }

    @Test func lateDiffAndShutdownCannotNavigateOrPublishToAnotherSelection() async throws {
        let service = ControlledGit(), model = GitWorkspace(root: "/repo", service: service)
        model.refresh()
        try await service.waitForSnapshots(1)
        await service.replySnapshot(0, .success(.init(repository: repository, branch: "main", head: nil, changes: [])))
        try await settle { model.state == .ready }
        let a = GitComparison.worktree(.init(path: "a", decoration: .init(worktree: "M")))
        let b = GitComparison.worktree(.init(path: "b", decoration: .init(worktree: "M")))
        var opened = 0
        model.onInspect = { opened += 1 }
        model.inspect(a)
        try await service.waitForDiffs(1)
        model.inspect(b)
        try await service.waitForDiffs(2)
        await service.replyDiff(1, "new diff")
        try await settle { model.diffState == .ready }
        await service.replyDiff(0, "old diff")
        try await Task.sleep(for: .milliseconds(20))
        #expect(model.comparison == b && model.diffText == "new diff" && opened == 2)
        model.inspect(a)
        try await service.waitForDiffs(3)
        model.stop()
        await service.replyDiff(2, "after closing")
        try await Task.sleep(for: .milliseconds(20))
        #expect(model.diffText != "after closing")
        model.refresh()
        model.inspect(b)
        #expect(opened == 3)
    }

    @Test func aggregatesAndInheritedIgnorePreserveTrackedStateAndProjectExclusion() async throws {
        let snapshot = GitSnapshot(repository: repository, branch: "main", head: nil, changes: [
            .init(path: "Sources/new.swift", decoration: .init(index: "A")),
            .init(path: "Sources/raw.swift", decoration: .init(isUntracked: true)),
            .init(path: "build", decoration: .init(ignoredReason: ".gitignore:1"))
        ])
        #expect(snapshot.decorations["/repo/Sources"]?.isMixed == true)
        #expect(snapshot.decorations["/repo"]?.ignoredReason == nil)
        let files = ProjectFiles(root: "/repo", reader: GitEmptyDirectoryReader())
        files.applyGitSnapshot(snapshot)
        #expect(files.decoration(for: "/repo/build/deep/new.txt").tone == .orange)
        files.exclude("/repo/Sources")
        let added = files.decoration(for: "/repo/Sources/new.swift")
        #expect(added.tone == .orange && added.index == "A")
        #expect(files.decoration(for: "/repo").tone == .green)
        #expect(!files.decoration(for: "/repo").isUntracked)
        let ignoredWithTrackedConflict = GitSnapshot(repository: repository, branch: "main", head: nil, changes: [
            .init(path: "ignored", decoration: .init(ignoredReason: ".gitignore:2")),
            .init(path: "ignored/tracked.txt", decoration: .init(worktree: "M", isConflict: true))
        ])
        let folder = try #require(ignoredWithTrackedConflict.decorations["/repo/ignored"])
        #expect(folder.tone == .orange && folder.isConflict && folder.worktree == "M")
    }

    @Test func lateCommitFilesCannotReplaceTheNewSelection() async throws {
        let service = ControlledGit(), model = GitWorkspace(root: "/repo", service: service)
        defer { model.stop() }
        model.refresh()
        try await service.waitForSnapshots(1)
        await service.replySnapshot(0, .success(.init(repository: repository, branch: "main", head: nil, changes: [])))
        try await settle { model.state == .ready }
        let a = GitCommit(oid: String(repeating: "a", count: 40), parents: [], author: "A", date: .now, subject: "A")
        let b = GitCommit(oid: String(repeating: "b", count: 40), parents: [], author: "B", date: .now, subject: "B")
        model.select(a)
        try await service.waitForFiles(1)
        model.select(b)
        try await service.waitForFiles(2)
        await service.replyFiles(1, [.init(path: "new.txt", status: "A")])
        try await settle { model.filesState == .ready }
        await service.replyFiles(0, [.init(path: "old.txt", status: "D")])
        try await Task.sleep(for: .milliseconds(20))
        #expect(model.selectedCommit == b && model.commitFiles.map(\.path) == ["new.txt"])
    }
}

private struct GitEmptyDirectoryReader: ProjectDirectoryReading {
    func children(of path: String) async throws -> [ProjectFile] { [] }
}

private actor ControlledGit: GitInspecting {
    private var snapshots: [CheckedContinuation<GitSnapshot, any Error>?] = []
    private var diffs: [CheckedContinuation<String, any Error>?] = []
    private var fileRequests: [CheckedContinuation<[GitCommitFile], any Error>?] = []

    func snapshot(at projectRoot: String) async throws -> GitSnapshot {
        try await withCheckedThrowingContinuation { snapshots.append($0) }
    }

    func diff(in repository: GitRepository, comparison: GitComparison) async throws -> String {
        try await withCheckedThrowingContinuation { diffs.append($0) }
    }

    func waitForSnapshots(_ count: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while snapshots.count < count, ContinuousClock.now < deadline { await Task.yield() }
        try #require(snapshots.count >= count)
    }

    func waitForDiffs(_ count: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while diffs.count < count, ContinuousClock.now < deadline { await Task.yield() }
        try #require(diffs.count >= count)
    }

    func replySnapshot(_ index: Int, _ value: Result<GitSnapshot, any Error>) {
        snapshots[index]?.resume(with: value)
        snapshots[index] = nil
    }

    func replyDiff(_ index: Int, _ value: String) {
        diffs[index]?.resume(returning: value)
        diffs[index] = nil
    }

    func history(
        in repository: GitRepository,
        revision: String,
        offset: Int,
        count: Int
    ) async throws -> GitHistoryPage {
        .init(commits: [], hasMore: false)
    }

    func files(in repository: GitRepository, commit: GitCommit) async throws -> [GitCommitFile] {
        try await withCheckedThrowingContinuation { fileRequests.append($0) }
    }

    func waitForFiles(_ count: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while fileRequests.count < count, ContinuousClock.now < deadline { await Task.yield() }
        try #require(fileRequests.count >= count)
    }

    func replyFiles(_ index: Int, _ value: [GitCommitFile]) {
        fileRequests[index]?.resume(returning: value)
        fileRequests[index] = nil
    }
}
