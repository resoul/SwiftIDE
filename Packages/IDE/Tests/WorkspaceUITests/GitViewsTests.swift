import AppKit
import Foundation
import IDEApplication
import Testing
@testable import WorkspaceUI

@Suite(.serialized) @MainActor
struct GitViewsTests {
    private func wait(_ test: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !test(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(test())
    }
    @Test func groupsKeepIndexAndWorktreeSeparateAndRefreshRetainsSelectionAndFocus() async throws {
        _ = NSApplication.shared
        let model = GitWorkspace(root: "/repo", service: ViewsGit())
        let changes = GitChangesViewController(model: model)
        let window = NSWindow(contentRect: NSRect(x: -2000, y: -2000, width: 370, height: 620), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentViewController = changes
        defer { changes.disconnect(); model.stop(); window.close() }
        model.refresh(); try await wait { model.state == .ready }
        #expect(changes.list.rows.filter { $0.key.hasSuffix(":both.txt") }.count == 2)
        #expect(!changes.list.rows.contains { $0.title == "ignored" })
        let index = try #require(changes.list.rows.firstIndex { $0.key == "index:both.txt" })
        window.makeFirstResponder(changes.focusTarget)
        changes.list.table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        try await wait { model.diffState == .ready }
        #expect(model.comparison == .index(ViewsGit.both))
        model.refresh(); try await wait { model.state == .ready && model.diffState == .ready }
        #expect(changes.list.selectedKey == "index:both.txt")
        #expect(window.firstResponder === changes.focusTarget)
        #expect(model.diffText == "+new line\n-old line\n")
    }
    @Test func branchesFilterAndInspectHistoryWhileDiffIsReadOnlyAndRendersBothThemes() async throws {
        _ = NSApplication.shared
        let model = GitWorkspace(root: "/repo", service: ViewsGit())
        let branches = GitBranchPickerViewController(model: model), log = GitLogViewController(model: model)
        let diff = GitDiffViewController(model: model)
        _ = branches.view; _ = log.view
        let window = NSWindow(contentRect: NSRect(x: -2000, y: -2000, width: 700, height: 420), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentViewController = diff
        defer { branches.disconnect(); log.disconnect(); diff.disconnect(); model.stop(); window.close() }
        model.refresh(); try await wait { model.state == .ready && model.historyState == .ready }
        branches.search.stringValue = "origin"
        branches.search.sendAction(branches.search.action, to: branches.search.target)
        #expect(branches.list.rows.map(\.title) == ["origin/main"])
        branches.list.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        branches.viewHistory(nil)
        #expect(model.historyTitle == "origin/main")
        try await wait { model.historyState == .ready }
        let commit = try #require(model.history.first)
        model.select(commit); try await wait { model.filesState == .ready }
        model.inspect(.commit(commit, try #require(model.commitFiles.first)))
        try await wait { model.diffState == .ready }
        #expect(!diff.text.isEditable && diff.text.string.contains("+new line"))
        for (label, theme) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            window.appearance = NSAppearance(named: theme)
            diff.view.layoutSubtreeIfNeeded()
            let bitmap = try #require(diff.view.bitmapImageRepForCachingDisplay(in: diff.view.bounds))
            diff.view.cacheDisplay(in: diff.view.bounds, to: bitmap)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: "/private/tmp/swiftide-git-diff-\(label).png"))
        }
    }
}

private struct ViewsGit: GitInspecting {
    static let both = GitChange(path: "both.txt", decoration: .init(index: "M", worktree: "M"))
    private let oid = String(repeating: "a", count: 40)
    func snapshot(at projectRoot: String) async throws -> GitSnapshot {
        .init(repository: .init(root: "/repo", gitDirectory: "/repo/.git", commonDirectory: "/repo/.git"),
              branch: "main",
              head: oid,
              changes: [Self.both, .init(path: "untracked.txt", decoration: .init(isUntracked: true)), .init(path: "ignored", decoration: .init(ignoredReason: ".gitignore:1"))],
              branches: [.init(reference: "refs/heads/main", oid: oid), .init(reference: "refs/remotes/origin/main", oid: oid)])
    }
    func history(in repository: GitRepository, revision: String, offset: Int, count: Int) async throws -> GitHistoryPage {
        .init(commits: [.init(oid: oid, parents: [], author: "Author", date: Date(timeIntervalSince1970: 100), subject: "Initial commit")], hasMore: false)
    }
    func files(in repository: GitRepository, commit: GitCommit) async throws -> [GitCommitFile] { [.init(path: "both.txt", status: "A")] }
    func diff(in repository: GitRepository, comparison: GitComparison) async throws -> String { "+new line\n-old line\n" }
}
