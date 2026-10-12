import AppKit
import Testing
import IDEApplication
@testable import WorkspaceUI

@Suite(.serialized) @MainActor
struct GitConflictWorkflowViewTests {
    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        try #require(predicate())
    }

    @Test func integrationRequiresReviewAndInvalidatesOnInputAndHeadChange() async throws {
        _ = NSApplication.shared
        let service = IntegrationViewFixture(), model = GitWorkspace(root: "/repo", service: service)
        let view = GitIntegrationViewController(workspace: model, kind: .rebase)
        defer {
            view.disconnect()
            model.stop()
        }
        _ = view.view
        model.refresh()
        try await wait { model.canMutate }
        #expect(view.review.isEnabled && !view.apply.isEnabled && view.apply.keyEquivalent.isEmpty)
        var chosen: GitIntegrationPlan?
        view.start = { chosen = $0 }
        view.reviewTarget(nil)
        #expect(view.apply.isEnabled)
        view.applyReviewed(nil)
        #expect(chosen?.head == IntegrationViewFixture.head && chosen?.target.name == "incoming" && chosen?.repository
            .root == "/repo")
        await service.moveHead()
        model.refresh()
        try await wait { model.canMutate }
        #expect(!view.apply.isEnabled)
        view.reviewTarget(nil)
        #expect(view.apply.isEnabled)
    }

    @Test func conflictControlsDistinguishTakeRestoreMarkAndResolvedStateInBothThemes() async throws {
        _ = NSApplication.shared
        let service = IntegrationViewFixture(), model = GitWorkspace(root: "/repo", service: service)
        await service.makeConflict()
        model.refresh()
        try await wait { model.canMutate }
        let conflict = await service.data()
        let view = GitConflictViewController(workspace: model, conflict: conflict)
        let window = NSWindow(
            contentRect: NSRect(x: -2000, y: 0, width: 800, height: 480),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = view
        defer {
            view.disconnect()
            model.stop()
            window.close()
        }
        let editor = NSTextView(usingTextLayoutManager: true)
        editor.string = "Result draft"
        editor.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        let scroll = NSScrollView()
        scroll.documentView = editor
        scroll.hasVerticalScroller = true
        view.canEditResult = { true }
        view.installEditor(scroll)
        window.setContentSize(NSSize(width: 800, height: 480))
        var taken: Int?, restored: Int?, marked = false
        view.takeTextSide = { taken = $0.stage }
        view.restoreStage = { restored = $0 }
        view.resolveWorking = {
            marked = true
        }
        let sender = NSButton()
        sender.tag = 3
        view.useSide(sender)
        #expect(taken == 3 && restored == nil)
        view.markWorking(nil)
        #expect(marked)
        #expect(editor.isEditable && view.resultHost.subviews.first === scroll)
        if ProcessInfo.processInfo.environment["SWIFTIDE_RENDER_CONFLICT"] == "1" {
            window.orderFront(nil)
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                window.appearance = NSAppearance(named: appearance)
                try await Task.sleep(for: .milliseconds(40))
                let root = try #require(window.contentView)
                root.layoutSubtreeIfNeeded()
                root.displayIfNeeded()

                func splits(_ node: NSView) -> [NSSplitView] {
                    (node as? NSSplitView).map { [$0] } ?? node.subviews.flatMap(splits)
                }

                let panes = try #require(splits(root).first)
                let widths = panes.subviews.map { $0.frame.width }
                #expect((widths.max() ?? 0) - (widths.min() ?? 0) < 2, "Sources start with equal widths")
                let bitmap = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
                root.cacheDisplay(in: root.bounds, to: bitmap)
                try #require(bitmap.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: "/private/tmp/swiftide-conflict-\(name).png"))
            }
        }

        view.installEditor(nil)
        view.useSide(sender)
        #expect(restored == 3)
        await service.resolve()
        model.refresh()
        try await wait { model.canMutate }
        #expect(!view.mark.isEnabled)
    }
}

private actor IntegrationViewFixture: GitInspecting, GitMutating, GitConflictReading {
    static let head = String(repeating: "a", count: 40)
    private var head = IntegrationViewFixture.head
    private var unmerged = false
    private let repository = GitRepository(root: "/repo", gitDirectory: "/repo/.git", commonDirectory: "/repo/.git")

    func snapshot(at projectRoot: String) async throws -> GitSnapshot {
        .init(
            repository: repository,
            branch: "main",
            head: head,
            changes: unmerged
                ? [.init(path: "a.txt", decoration: .init(index: "U", worktree: "U", isConflict: true))]
                : [],
            branches: [
                .init(reference: "refs/heads/main", oid: head),
                .init(reference: "refs/heads/incoming", oid: String(repeating: "b", count: 40))
            ]
        )
    }

    func data() -> GitConflict {
        .init(
            repository: repository,
            path: "a.txt",
            sides: (1...3).map {
                .init(
                    stage: $0,
                    mode: "100644",
                    oid: Self.head,
                    text: $0 == 1
                        ? "base\n"
                        : $0 == 2 ? "ours\n" : "theirs\n",
                    bytes: 6
                )
            },
            indexToken: "index",
            workingToken: "work",
            workingText: "markers",
            workingExists: true,
            integration: .init(
                kind: .rebase,
                token: "operation",
                originalHead: Self.head,
                detail: "Rebase in progress"
            )
        )
    }

    func conflict(in snapshot: GitSnapshot, path: String) async throws -> GitConflict { data() }

    func history(
        in repository: GitRepository,
        revision: String,
        offset: Int,
        count: Int
    ) async throws -> GitHistoryPage {
        .init(commits: [], hasMore: false)
    }

    func files(in repository: GitRepository, commit: GitCommit) async throws -> [GitCommitFile] { [] }

    func diff(in repository: GitRepository, comparison: GitComparison) async throws -> String { "" }

    func perform(
        _ action: GitAction,
        expected: GitSnapshot,
        output: @escaping @Sendable (String) -> Void
    ) async throws {}

    func moveHead() { head = String(repeating: "c", count: 40) }

    func makeConflict() { unmerged = true }

    func resolve() { unmerged = false }
}
