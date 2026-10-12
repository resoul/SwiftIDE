import AppKit
import IDEApplication
import Testing
@testable import WorkspaceUI

private actor TrackingViewsService: GitInspecting, GitMutating, GitTrackingPlanning {
    var changed = false
    var local: GitBranch { .init(
        reference: "refs/heads/local",
        oid: String(repeating: "a", count: 40),
        upstream: "refs/remotes/team/fork/release/remote",
        upstreamRemote: "team/fork",
        upstreamSource: "refs/heads/release/remote"
    ) }
    var source: GitBranch { .init(reference: "refs/remotes/team/fork/release/remote", oid: String(
        repeating: changed
            ? "b"
            : "a",
        count: 40
    )) }

    func moveSource() { changed = true }

    func snapshot(at projectRoot: String) async throws -> GitSnapshot {
        .init(
            repository: .init(root: "/repo", gitDirectory: "/repo/.git", commonDirectory: "/repo/.git"),
            branch: "local",
            head: local.oid,
            changes: [],
            branches: [local, source],
            remotes: ["origin", "team/fork"]
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

    func perform(
        _ action: GitLocalAction,
        expected: GitSnapshot,
        output: @escaping @Sendable (String) -> Void
    ) async throws {}

    func planTracking(in snapshot: GitSnapshot, request: GitTrackingRequest) async throws -> GitTrackingPlan {
        .init(
            repository: snapshot.repository,
            request: request,
            remote: request.source == nil ? nil : "team/fork",
            remoteSource: request.source == nil
                ? nil
                : "refs/heads/release/remote",
            configurationToken: "fixture"
        )
    }
}

@Suite(.serialized)
@MainActor
struct GitTrackingViewTests {
    private func wait(_ predicate: () -> Bool) async throws {
        let end = ContinuousClock.now + .seconds(5)
        while !predicate(), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(2)) }
        try #require(predicate())
    }

    @Test func trackingRequiresReviewInvalidatesDraftAndMovedRefsAndShowsBothAppearances() async throws {
        _ = NSApplication.shared
        let service = TrackingViewsService(), workspace = GitWorkspace(root: "/repo", service: service)
        let controller = GitTrackingViewController(workspace: workspace)
        let window = NSWindow(
            contentRect: NSRect(x: -2000, y: -2000, width: 650, height: 430),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        defer {
            controller.disconnect()
            workspace.stop()
            window.close()
        }
        workspace.refresh()
        try await wait { workspace.canMutate }
        let source = try #require(workspace.snapshot?.branches.first { $0.isRemote })
        controller.select(source)
        #expect(controller.name.stringValue == "release/remote")
        #expect(!controller.apply.isEnabled && controller.apply.keyEquivalent.isEmpty)
        var submitted: [GitTrackingPlan] = []
        controller.start = { submitted.append($0) }
        controller.applyReviewed(nil)
        #expect(submitted.isEmpty)
        controller.reviewSelection(nil)
        try await wait { controller.model.canApply }
        #expect(controller.details.stringValue.contains("team/fork") && controller.details.stringValue
            .contains(source.oid))
        #expect(submitted.isEmpty)
        for (name, theme) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            window.appearance = NSAppearance(named: theme)
            controller.view.layoutSubtreeIfNeeded()
            controller.view.displayIfNeeded()
            #expect(controller.apply.frame.height > 15 && controller.details.frame.height > 60)
            if ProcessInfo.processInfo.environment["SWIFTIDE_RENDER_TRACKING"] == "1" {
                let bitmap = try #require(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
                controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
                try #require(bitmap.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: "/private/tmp/swiftide-tracking-\(name).png"))
            }
        }
        controller.name.stringValue = "chosen/local"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        #expect(!controller.apply.isEnabled)
        controller.reviewSelection(nil)
        try await wait { controller.model.canApply }
        await service.moveSource()
        workspace.refresh()
        try await wait { workspace.canMutate }
        #expect(!controller.apply.isEnabled && controller.name.stringValue == "chosen/local")
        controller.reviewSelection(nil)
        try await wait { controller.model.canApply }
        controller.applyReviewed(nil)
        #expect(submitted.count == 1 && submitted.first?.request.name == "chosen/local")
        controller.mode.selectItem(at: 2)
        controller.selectionChanged(nil)
        #expect(controller.source.isHidden && controller.name.isHidden && !controller.local.isHidden)
        controller.reviewSelection(nil)
        try await wait { controller.model.canApply }
        #expect(controller.model.plan?.remote == nil && controller.details.stringValue
            .contains("Previous upstream: refs/remotes/team/fork/release/remote"))
    }

    @Test func networkFormsSuggestTheActualUpstreamRemoteAndSource() async throws {
        _ = NSApplication.shared
        let service = TrackingViewsService(), workspace = GitWorkspace(root: "/repo", service: service)
        let pushModel = GitPushReview(workspace: workspace), pullModel = GitPullReview(workspace: workspace)
        let push = GitPushViewController(model: pushModel), pull = GitPullViewController(model: pullModel)
        _ = push.view
        _ = pull.view
        defer {
            push.disconnect()
            pull.disconnect()
            pushModel.stop()
            pullModel.stop()
            workspace.stop()
        }
        workspace.refresh()
        try await wait { workspace.canMutate }
        push.select(branch: nil, remote: nil)
        pull.select(remote: nil, source: nil)
        #expect(push.remote.titleOfSelectedItem == "team/fork" && push.destination.stringValue == "release/remote")
        #expect(pull.remote.titleOfSelectedItem == "team/fork" && pull.source.stringValue == "release/remote")
        push.destination.stringValue = "explicit"
        pull.source.stringValue = "explicit"
        await service.moveSource()
        workspace.refresh()
        try await wait { workspace.canMutate }
        #expect(push.destination.stringValue == "explicit" && pull.source.stringValue == "explicit")
        push.select(branch: nil, remote: "origin")
        pull.select(remote: "origin", source: "chosen")
        #expect(push.remote.titleOfSelectedItem == "origin" && push.destination.stringValue == "local")
        #expect(pull.remote.titleOfSelectedItem == "origin" && pull.source.stringValue == "chosen")
    }
}
