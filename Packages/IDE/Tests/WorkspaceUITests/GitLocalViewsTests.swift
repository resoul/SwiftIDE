import AppKit
import Testing
import IDEApplication
@testable import WorkspaceUI

@Suite(.serialized) @MainActor
struct GitLocalViewsTests {
    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(predicate())
    }
    @Test func wholeFileButtonsAndCommitDraftFollowBusySuccessAndFailure() async throws {
        _ = NSApplication.shared
        let service = ActionViewsGit(), model = GitWorkspace(root: "/repo", service: service)
        let changes = GitChangesViewController(model: model)
        let window = NSWindow(contentRect: NSRect(x: -2000, y: -2000, width: 320, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentViewController = changes
        window.orderFront(nil)
        defer { changes.disconnect(); model.stop(); window.close() }
        model.refresh(); try await wait { model.state == .ready }
        let index = try #require(changes.list.rows.firstIndex { $0.key == "worktree:both.txt" })
        changes.list.table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        #expect(changes.stage.isEnabled && !changes.unstage.isEnabled)
        changes.stageSelected(nil)
        #expect(!changes.stage.isEnabled && !changes.message.isEditable)
        try await wait { model.operationState == .succeeded && model.state == .ready }
        #expect(await service.last == .stage(ActionViewsGit.change))
        let staged = try #require(changes.list.rows.firstIndex { $0.key == "index:both.txt" })
        changes.list.table.selectRowIndexes(IndexSet(integer: staged), byExtendingSelection: false)
        #expect(changes.unstage.isEnabled && !changes.stage.isEnabled)
        changes.unstageSelected(nil)
        try await wait { model.operationState == .succeeded && model.state == .ready }
        #expect(await service.last == .unstage(ActionViewsGit.change))
        changes.focusCommitMessage(); changes.message.string = "  \n"
        changes.textDidChange(Notification(name: NSText.didChangeNotification))
        #expect(!changes.commit.isEnabled)
        changes.message.string = "Keep draft after failure"
        changes.textDidChange(Notification(name: NSText.didChangeNotification))
        await service.failNext()
        changes.commitStaged(nil)
        try await wait { model.operationState == .failed("hook failed") && model.state == .ready }
        #expect(changes.message.string == "Keep draft after failure")
        for (name, theme) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            window.appearance = NSAppearance(named: theme)
            changes.view.layoutSubtreeIfNeeded()
            let bitmap = try #require(changes.view.bitmapImageRepForCachingDisplay(in: changes.view.bounds))
            changes.view.cacheDisplay(in: changes.view.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/private/tmp/swiftide-git-actions-\(name).png"))
        }
        changes.commitStaged(nil)
        try await wait { model.operationState == .succeeded && model.state == .ready }
        #expect(changes.message.string.isEmpty)
    }
    @Test func branchActionsDistinguishCreateLocalSwitchAndRemoteInspection() async throws {
        let service = ActionViewsGit(), model = GitWorkspace(root: "/repo", service: service)
        let picker = GitBranchPickerViewController(model: model)
        _ = picker.view
        defer { picker.disconnect(); model.stop() }
        model.prepareCheckout = { _ in true }
        model.refresh(); try await wait { model.state == .ready }
        let remote = try #require(picker.list.rows.firstIndex { $0.key == "refs/remotes/origin/main" })
        picker.list.table.selectRowIndexes(IndexSet(integer: remote), byExtendingSelection: false)
        #expect(!picker.switchBranch.isEnabled)
        picker.branchName.stringValue = "new/local"
        picker.controlTextDidChange(Notification(name: NSText.didChangeNotification))
        #expect(picker.createBranch.isEnabled)
        picker.createNamed(nil)
        try await wait { model.operationState == .succeeded && model.state == .ready }
        #expect(await service.last == .createBranch("new/local"))
        let local = try #require(picker.list.rows.firstIndex { $0.key == "refs/heads/other" })
        picker.list.table.selectRowIndexes(IndexSet(integer: local), byExtendingSelection: false)
        #expect(picker.switchBranch.isEnabled)
        picker.switchSelected(nil)
        try await wait { model.operationState == .succeeded && model.state == .ready }
        #expect(await service.last == .switchBranch(try #require(model.snapshot?.branches.first { $0.name == "other" })))
    }
}

private actor ActionViewsGit: GitInspecting, GitMutating {
    static let change = GitChange(path: "both.txt", decoration: .init(index: "M", worktree: "M"))
    private(set) var last: GitLocalAction?
    private var failing = false
    func snapshot(at projectRoot: String) async throws -> GitSnapshot {
        .init(repository: .init(root: "/repo", gitDirectory: "/repo/.git", commonDirectory: "/repo/.git"), branch: "main", head: String(repeating: "a", count: 40), changes: [Self.change], branches: [
            .init(reference: "refs/heads/other", oid: String(repeating: "b", count: 40)),
            .init(reference: "refs/remotes/origin/main", oid: String(repeating: "a", count: 40))
        ])
    }
    func history(in repository: GitRepository, revision: String, offset: Int, count: Int) async throws -> GitHistoryPage { .init(commits: [], hasMore: false) }
    func files(in repository: GitRepository, commit: GitCommit) async throws -> [GitCommitFile] { [] }
    func diff(in repository: GitRepository, comparison: GitComparison) async throws -> String { "diff" }
    func perform(_ action: GitLocalAction, expected: GitSnapshot, output: @escaping @Sendable (String) -> Void) async throws {
        last = action
        output("hook output\n")
        if failing { failing = false; throw GitInspectionError.failed("hook failed") }
    }
    func failNext() { failing = true }
}
