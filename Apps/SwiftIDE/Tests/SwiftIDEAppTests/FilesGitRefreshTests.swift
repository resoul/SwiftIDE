import AppKit
import IDEApplication
import Testing
@testable import SwiftIDE

private actor CountedFilesReader: ProjectDirectoryReading {
    private(set) var calls = 0

    func children(of path: String) async throws -> [ProjectFile] {
        calls += 1

        return [.init(path: path + "/a.txt", isDirectory: false)]
    }
}

private actor FilesStatusService: GitInspecting {
    private var revision = 0

    func snapshot(at projectRoot: String) async throws -> GitSnapshot {
        revision += 1

        return GitSnapshot(
            repository: .init(
                root: projectRoot,
                gitDirectory: projectRoot + "/.git",
                commonDirectory: projectRoot + "/.git"
            ),
            branch: "main",
            head: nil,
            changes: [.init(path: "a.txt", decoration: .init(worktree: revision.isMultiple(of: 2) ? "M" : "?"))],
            capturedAt: Date(timeIntervalSince1970: Double(revision))
        )
    }

    func history(
        in repository: GitRepository,
        revision: String,
        offset: Int,
        count: Int
    ) async throws -> GitHistoryPage { .init(
        commits: [],
        hasMore: false
    ) }

    func files(in repository: GitRepository, commit: GitCommit) async throws -> [GitCommitFile] { [] }

    func diff(in repository: GitRepository, comparison: GitComparison) async throws -> String { "" }
}

extension NativeAppTests {
    @Suite(.serialized)
    @MainActor
    struct FilesGitRefreshTests {
        private func wait(_ predicate: () -> Bool) async throws {
            let end = ContinuousClock.now + .seconds(5)
            while !predicate(), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(1)) }
            try #require(predicate())
        }

        @Test func statusSnapshotsDoNotReenumerateFoldersAndExplicitRefreshStillDoes() async throws {
            _ = NSApplication.shared
            let root = "/SwiftIDE-nonexistent-files-refresh-\(UUID())"
            let reader = CountedFilesReader()
            let files = ProjectFiles(root: root, reader: reader)
            let git = GitWorkspace(root: root, service: FilesStatusService())
            let project = ProjectWorkspaceController(module: WorkspaceModuleFactory().make(
                files: files,
                git: git,
                agent: AppCompositionRoot.makeDemoAgentSession()
            ))
            defer { project.closeProject() }
            try await wait { files.state(of: root) == .loaded && git.state == .ready }
            #expect(await reader.calls == 1)
            for _ in 0..<8 {
                git.refresh()
                try await wait { git.state == .ready }
            }
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
            #expect(await reader.calls == 1, "new snapshots/colours do not trigger directory reads")
            #expect(files.decorations[root + "/a.txt"] != nil)
            files.refresh()
            try await wait { files.state(of: root) == .loaded && git.state == .ready }
            #expect(await reader.calls == 2, "explicit filesystem refresh still updates listings")
        }
    }
}
