import AppKit
import IDEApplication
import Testing
@testable import WorkspaceUI

private actor StashViewsService: GitInspecting, GitMutating, GitStashReading {
    let entry = GitStashEntry(
        selector: "stash@{0}",
        oid: String(repeating: "a", count: 40),
        date: .init(timeIntervalSince1970: 1),
        message: "Saved changes"
    )

    func snapshot(at projectRoot: String) async throws -> GitSnapshot {
        .init(repository: .init(
            root: projectRoot,
            gitDirectory: projectRoot + "/.git",
            commonDirectory: projectRoot + "/.git"
        ), branch: "main", head: entry.oid, changes: [])
    }

    func stashes(in repository: GitRepository) async throws -> GitStashList {
        .init(entries: [entry], token: "fixture")
    }

    func perform(
        _ action: GitAction,
        expected: GitSnapshot,
        output: @escaping @Sendable (String) -> Void
    ) async throws {}

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
}

@Suite(.serialized)
@MainActor
struct GitStashViewTests {
    private func wait(_ predicate: () -> Bool) async throws {
        let end = ContinuousClock.now + .seconds(5)
        while !predicate(), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(2)) }
        try #require(predicate())
    }

    @Test func nativeReviewRequiresExplicitInclusionAndActionAndInvalidatesEveryEdit() async throws {
        _ = NSApplication.shared
        let workspace = GitWorkspace(root: "/repo", service: StashViewsService())
        let controller = GitStashViewController(workspace: workspace)
        let window = NSWindow(
            contentRect: NSRect(x: -2000, y: -2000, width: 720, height: 650),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 720, height: 650))
        defer {
            controller.disconnect()
            workspace.stop()
            window.close()
        }
        workspace.refresh()
        try await wait { controller.model.canReview }
        #expect(controller.inclusion.indexOfSelectedItem == 0 && controller.restoreIndex.state == .off)
        #expect(controller.restoreIndex.isHidden && !controller.apply.isEnabled && controller.apply.keyEquivalent
            .isEmpty)
        var submitted: [GitStashPlan] = []
        controller.start = { submitted.append($0) }
        controller.applyReviewed(nil)
        #expect(submitted.isEmpty)
        controller.inclusion.selectItem(at: 2)
        controller.selectionChanged(nil)
        controller.reviewSelection(nil)
        #expect(controller.apply.isEnabled && submitted.isEmpty)
        #expect(controller.details.stringValue.contains("AND ignored") && controller.details.stringValue
            .contains("ALL"))
        controller.message.stringValue = "edited"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        #expect(!controller.apply.isEnabled)
        controller.reviewSelection(nil)
        controller.applyReviewed(nil)
        #expect(submitted.count == 1 && submitted[0].request == .create(message: "edited", inclusion: .ignored))
        controller.mode.selectItem(at: 3)
        controller.selectionChanged(nil)
        #expect(!controller.review.isEnabled && controller.message.isHidden && controller.inclusion.isHidden)
        controller.list.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        controller.reviewSelection(nil)
        #expect(controller.apply.isEnabled && controller.apply.title == "Drop stash")
        #expect(controller.details.stringValue.contains("Deletes this saved entry") && controller.details.stringValue
            .contains("stash@{0}"))
        controller.mode.selectItem(at: 2)
        controller.selectionChanged(nil)
        controller.restoreIndex.state = .on
        controller.selectionChanged(nil)
        controller.reviewSelection(nil)
        #expect(controller.details.stringValue.contains("saved index"))
        #expect(submitted.count == 1)
        for (name, theme) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            window.appearance = NSAppearance(named: theme)
            controller.view.layoutSubtreeIfNeeded()
            let bitmap = try #require(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
            controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: "/private/tmp/swiftide-stash-\(name).png"))
            #expect(controller.apply.convert(controller.apply.bounds, to: controller.view).minY >= 0)
        }
        var previewed: [GitStashEntry] = []
        controller.preview = { previewed.append($0) }
        controller.list.openSelected(nil)
        #expect(previewed.count == 1 && submitted.count == 1)
        controller.disconnect()
        controller.applyReviewed(nil)
        #expect(submitted.count == 1)
    }
}
