import AppKit
import Foundation
import IDEApplication
import Testing
@testable import WorkspaceUI

private actor ExtendedViewsGit: GitInspecting, GitMutating, GitPartialReading, GitManagementPlanning,
    GitInteractiveRebasePlanning, GitRepositoryOperationPlanning, GitHostingRemoteReading {
    private let oid = String(repeating: "a", count: 40)
    static let change = GitChange(path: "a.txt", decoration: .init(worktree: "M"))
    private var token = "first"
    private(set) var actions: [GitAction] = []

    func move() { token = "next" }

    func hostingRemote(in snapshot: GitSnapshot, remote: String) async throws -> String {
        "git@github.com:org/repo.git"
    }

    func snapshot(at root: String) async throws -> GitSnapshot {
        .init(
            repository: .init(root: root, gitDirectory: root + "/.git", commonDirectory: root + "/.git"),
            branch: "main",
            head: oid,
            changes: [Self.change],
            branches: [.init(reference: "refs/heads/main", oid: oid), .init(reference: "refs/heads/onto", oid: oid)],
            mutationToken: token,
            remotes: ["origin"]
        )
    }

    func partialDiff(in snapshot: GitSnapshot, comparison: GitComparison) async throws -> GitPartialDiff {
        try .init(
            repository: snapshot.repository,
            comparison: comparison,
            text: "diff --git a/a.txt b/a.txt\n--- a/a.txt\n+++ b/a.txt\n@@ -1,1 +1,1 @@\n-old\n+new\n",
            token: token,
            base: Data("old\n".utf8),
            mode: "100644",
            removeWhenEmpty: false
        )
    }

    func planManagement(in snapshot: GitSnapshot, request: GitManagementRequest) async throws -> GitManagementPlan {
        .init(
            repository: snapshot.repository,
            request: request,
            token: token,
            oid: oid,
            url: nil,
            summary: "Reviewed action"
        )
    }

    func planInteractiveRebase(in snapshot: GitSnapshot, target: GitBranch) async throws -> GitInteractiveRebasePlan {
        .init(
            source: .init(repository: snapshot.repository, kind: .rebase, head: oid, branch: "main", target: target),
            commits: ["a", "b"].map { .init(
                oid: String(repeating: $0, count: 40),
                parents: [],
                author: "Author",
                date: .distantPast,
                subject: "Commit " + $0
            ) },
            token: token
        )
    }

    func planRepositoryOperation(
        in snapshot: GitSnapshot,
        request: GitRepositoryOperationRequest
    ) async throws -> GitRepositoryOperationPlan {
        .init(
            repository: snapshot.repository,
            request: request,
            head: oid,
            branch: "main",
            target: oid,
            token: token,
            summary: "Exact reviewed operation"
        )
    }

    func perform(
        _ action: GitAction,
        expected: GitSnapshot,
        output: @escaping @Sendable (String) -> Void
    ) async throws {
        actions.append(action)
    }

    func history(
        in repository: GitRepository,
        revision: String,
        offset: Int,
        count: Int
    ) async throws -> GitHistoryPage {
        .init(commits: offset == 0 ? Self.history : [], hasMore: false)
    }

    static let history = ["c", "d"].map { GitCommit(
        oid: String(repeating: $0, count: 40),
        parents: [],
        author: "Author",
        date: .distantPast,
        subject: "Commit " + $0
    ) }

    func files(in repository: GitRepository, commit: GitCommit) async throws -> [GitCommitFile] { [] }

    func diff(in repository: GitRepository, comparison: GitComparison) async throws -> String { "" }
}

@MainActor private final class PreviewHostingStore: GitHostingAccountStore {
    let value: GitHostingAccount

    init(_ account: GitHostingAccount) { value = account }

    func load() throws -> [GitHostingAccount] { [value] }

    func save(_ accounts: [GitHostingAccount]) throws {}
}
private actor PreviewHostingAPI: GitHostingAPI, GitHostingCredentials {
    private(set) var calls = 0

    func token(account: UUID) async throws -> String { "fixture" }

    func save(token: String, account: UUID) async throws { Issue.record("Unexpected write") }

    func remove(account: UUID) async throws { Issue.record("Unexpected write") }

    func authenticate(_ account: GitHostingAccount, token: String) async throws -> String { "fixture" }

    func branchSHA(in repository: GitHostedRepository, branch: String) async throws -> String {
        String(repeating: "a", count: 40)
    }

    func requests(in repository: GitHostedRepository) async throws -> GitHostingPage<GitHostingRequest> {
        calls += 1

        return .init(items: [.init(
            number: 12,
            title: "Improve editor navigation",
            source: "feature/editor",
            target: "main",
            sha: String(repeating: "a", count: 40),
            url: URL(string: "https://github.com/org/repo/pull/12")!,
            draft: true
        )])
    }

    func checks(in repository: GitHostedRepository, sha: String) async throws -> GitHostingPage<GitHostingCheck> {
        calls += 1

        return .init(items: [
            .init(name: "Unit tests", state: "success"),
            .init(name: "Build macOS", state: "in_progress"),
            .init(name: "Lint", state: "failure")
        ])
    }

    func create(in repository: GitHostedRepository, request: GitHostingCreate) async throws -> GitHostingRequest {
        Issue.record("Unexpected publication")
        throw GitInspectionError.failed("No publication in visual tests")
    }
}

@Suite(.serialized) @MainActor
struct GitExtendedViewsTests {
    private func wait(_ predicate: () async -> Bool) async throws {
        let end = ContinuousClock.now + .seconds(5)
        while !(await predicate()), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(5)) }
        try #require(await predicate())
    }

    private func window(_ controller: NSViewController, name: String) throws -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: -3000, y: -3000, width: 780, height: 760),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.contentView?.layoutSubtreeIfNeeded()

        return window
    }

    /// Draws both appearances; PNGs are written only with `SWIFTIDE_RENDER_GIT_EXTENDED=1`.
    private func capture(_ controller: NSViewController, window: NSWindow, name: String) throws {
        for (theme, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            window.appearance = NSAppearance(named: theme)
            let view = controller.view
            view.layoutSubtreeIfNeeded()
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let bytes = try #require(bitmap.representation(using: .png, properties: [:]))
            if ProcessInfo.processInfo.environment["SWIFTIDE_RENDER_GIT_EXTENDED"] == "1" {
                try bytes.write(to: URL(fileURLWithPath: "/private/tmp/swiftide-git-" + name + "-" + suffix + ".png"))
            }
        }
    }

    @Test func partialSelectionIsExplicitAndAChangedDiffClearsNativeSelection() async throws {
        let service = ExtendedViewsGit(), model = GitWorkspace(root: "/fixture", service: service)
        let controller = GitDiffViewController(model: model)
        let window = try window(controller, name: "partial")
        defer {
            controller.disconnect()
            model.stop()
            window.close()
        }
        model.refresh()
        try await wait { model.canMutate }
        model.inspect(.worktree(ExtendedViewsGit.change))
        try await wait { model.diffState == .ready }
        #expect(controller.applyHunk.isEnabled && !controller.text.isEditable)
        #expect(await service.actions.isEmpty)
        let line = try #require(model.partialDiff?.hunks.first?.lines.first { $0.kind == .addition })
        controller.text.setSelectedRange(NSRange(location: line.range.location, length: line.range.length))
        controller.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification))
        #expect(controller.applyLines.isEnabled)
        try capture(controller, window: window, name: "partial")
        await service.move()
        model.refresh()
        try await wait { model.diffState == .ready && model.partialDiff?.token == "next" }
        #expect(controller.text.selectedRange().length == 0 && !controller.applyLines.isEnabled)
        // The workspace refreshes after the action and clears its diff, so compare with the presented one.
        let presented = try #require(model.partialDiff)
        controller.applyHunk.performClick(nil)
        try await wait { await service.actions.count == 1 }
        let action = try #require(await service.actions.first)
        if case .partial(let selection) = action {
            #expect(selection.diff == presented && selection.diff.token == "next")
            #expect(selection.lines == presented.hunks.first?.changedIDs)
        }
        else { Issue.record("Expected selected block action") }
    }

    @Test func managementRequiresReviewAndInvalidatesEditedFields() async throws {
        let model = GitWorkspace(root: "/fixture", service: ExtendedViewsGit())
        let controller = GitManagementViewController(workspace: model)
        let window = try window(controller, name: "management")
        defer {
            controller.disconnect()
            model.stop()
            window.close()
        }
        model.refresh()
        try await wait { model.canMutate }
        controller.name.stringValue = "main"
        controller.value.stringValue = "renamed"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        #expect(!controller.apply.isEnabled)
        controller.reviewButton.performClick(nil)
        try await wait { controller.review.canApply }
        #expect(controller.apply.isEnabled)
        try capture(controller, window: window, name: "management")
        var started: GitManagementPlan?
        controller.start = { started = $0 }
        controller.apply.performClick(nil)
        #expect(started?.request.value == "renamed")
        controller.value.stringValue = "edited"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        #expect(!controller.apply.isEnabled && controller.review.plan == nil)
    }

    @Test func interactiveReplayMovesWholeCommitsAndFirstSquashMustBeFixedBeforeApply() async throws {
        let model = GitWorkspace(root: "/fixture", service: ExtendedViewsGit())
        let review = GitInteractiveRebaseReview(workspace: model)
        let controller = GitInteractiveRebaseViewController(model: review)
        let window = try window(controller, name: "interactive")
        defer {
            controller.disconnect()
            model.stop()
            window.close()
        }
        model.refresh()
        try await wait { model.canMutate }
        review.review(target: try #require(model.snapshot?.branches.first { $0.name == "onto" }))
        try await wait { review.canApply }
        let old = try #require(review.plan)
        review.move(from: 0, to: 1)
        #expect(review.plan?.steps.first?.commit == old.steps.last?.commit)
        review.setAction(.squash, at: 0)
        #expect(!review.canApply)
        review.move(from: 0, to: 1)
        #expect(review.canApply && review.plan?.steps.last?.action == .squash)
        try capture(controller, window: window, name: "interactive")
        review.stop()
        #expect(!review.canApply && review.plan == nil)
    }

    @Test func hostingSelectionDoesNotRecurseOrReadUntilExplicitRefreshAndRendersBoundCI() async throws {
        let workspace = GitWorkspace(root: "/fixture", service: ExtendedViewsGit())
        let account = try GitHostingAccount(
            service: .github,
            webURL: #require(URL(string: "https://github.com")),
            login: "fixture"
        )
        let api = PreviewHostingAPI()
        let accounts = GitHostingAccounts(store: PreviewHostingStore(account), credentials: api, api: api)
        let model = GitHostingWorkspace(workspace: workspace, accounts: accounts)
        let controller = GitHostingViewController(model: model)
        let window = try window(controller, name: "hosting")
        defer {
            controller.disconnect()
            workspace.stop()
            window.close()
        }
        workspace.refresh()
        try await wait { workspace.state == .ready && model.accountID == account.id }
        #expect(await api.calls == 0)
        #expect(model.remote == "origin")
        model.refresh()
        try await wait { model.state == .ready && !model.requests.isEmpty }
        #expect(model.requests.first?.number == 12 && model.checksSHA == workspace.snapshot?.head)
        #expect(model.checks.map(\.state) == ["success", "in_progress", "failure"])
        try capture(controller, window: window, name: "hosting")
        model.stop()
        #expect(!model.canRead && !model.canCreate)
    }

    @Test func addSubmoduleFormShowsAndSendsOnlyTheReviewedRepositoryAddress() async throws {
        let model = GitWorkspace(root: "/fixture", service: ExtendedViewsGit())
        let review = GitRepositoryOperationReview(workspace: model)
        let controller = GitRepositoryOperationViewController(model: review)
        let window = try window(controller, name: "operation")
        defer {
            controller.disconnect()
            model.stop()
            window.close()
        }
        model.refresh()
        try await wait { model.canMutate }
        controller.select(.addSubmodule, value: "vendor/module")
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(controller.address.window === window && !controller.address.isHidden)
        #expect(controller.address.frame.width > 0 && controller.address.frame.height > 0)
        #expect(!controller.reviewButton.isEnabled)
        controller.address.stringValue = "https://example.test/module.git"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        controller.reviewButton.performClick(nil)
        try await wait { review.canApply }
        #expect(review.plan?.request == .init(
            kind: .addSubmodule,
            value: "vendor/module",
            url: "https://example.test/module.git"
        ))
        try capture(controller, window: window, name: "operation")
        controller.address.stringValue = "https://example.test/other.git"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        #expect(!review.canApply && review.plan == nil)
        controller.select(.updateSubmodule, value: "vendor/module")
        #expect(controller.address.isHidden)
        controller.reviewButton.performClick(nil)
        try await wait { review.canApply }
        #expect(review.plan?.request.url == "")
    }

    @Test func historyCIIsAnExplicitCommandForTheSelectedCommitAndLabelsOnlyThatCommit() async throws {
        let model = GitWorkspace(root: "/fixture", service: ExtendedViewsGit())
        let controller = GitLogViewController(model: model)
        let window = try window(controller, name: "history")
        defer {
            controller.disconnect()
            model.stop()
            window.close()
        }
        model.refresh()
        try await wait { model.history.count == 2 && controller.commits.rows.count == 2 }
        #expect(controller.ci.isHidden)
        var requested: [String] = []
        controller.inspectCI = { requested.append($0.oid) }
        #expect(!controller.ci.isHidden && !controller.ci.isEnabled)
        let second = ExtendedViewsGit.history[1]
        controller.commits.table.selectRowIndexes([1], byExtendingSelection: false)
        try await wait { model.selectedCommit == second && controller.ci.isEnabled }
        #expect(requested.isEmpty)
        controller.ci.performClick(nil)
        #expect(requested == [second.oid])
        controller.presentCI(
            sha: second.oid,
            checks: [.init(name: "build", state: "success"), .init(name: "lint", state: "failure")],
            limited: false,
            receivedAt: .now,
            source: "https://github.com/org/repo"
        )
        #expect(controller.commits.rows[1].detail.contains("CI: failed/cancelled · https://github.com/org/repo"))
        #expect(!controller.commits.rows[0].detail.contains("CI:"))
        controller.presentCI(sha: second.oid, checks: [], limited: false, receivedAt: .now)
        #expect(controller.commits.rows[1].detail.contains("CI: none reported"))
    }
}
