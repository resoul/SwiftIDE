import AppKit
import Testing
import IDEApplication
@testable import WorkspaceUI

@Suite(.serialized) @MainActor
struct GitPullViewTests {
    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        try #require(predicate())
    }
    @Test func reviewRequiredInputChangesInvalidateAndFailureKeepsFormInBothAppearances() async throws {
        _ = NSApplication.shared
        let service = PullViewsService(), workspace = GitWorkspace(root: "/repo", service: service), model = GitPullReview(workspace: workspace)
        let controller = GitPullViewController(model: model)
        let window = NSWindow(contentRect: NSRect(x: -2000, y: 0, width: 660, height: 490), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentViewController = controller
        defer { model.stop(); workspace.stop(); controller.disconnect(); window.close() }
        _ = controller.view; workspace.refresh(); try await wait { workspace.canMutate }
        workspace.prepareCheckout = { _ in true }; controller.select(remote: nil, source: nil)
        #expect(controller.remote.titleOfSelectedItem == "origin" && controller.source.stringValue == "tracked/main")
        #expect(!controller.pull.isEnabled && controller.review.isEnabled && controller.pull.keyEquivalent.isEmpty)
        controller.reviewSource(nil); try await wait { model.canPull }
        #expect(controller.pull.isEnabled)
        #expect(await service.writes == 0)
        controller.source.stringValue = "chosen/new"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        #expect(!controller.pull.isEnabled)
        await service.addBranch(); workspace.refresh(); try await wait { workspace.canMutate }
        #expect(controller.source.stringValue == "chosen/new", "Background branch additions preserve the source draft")
        controller.reviewSource(nil); try await wait { model.canPull }
        #expect(model.plan?.source == "chosen/new" && model.plan?.url == "ssh://git@host/pull.git")
        if ProcessInfo.processInfo.environment["SWIFTIDE_RENDER_PULL"] == "1" {
            window.orderFront(nil)
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                window.appearance = NSAppearance(named: appearance)
                try await Task.sleep(for: .milliseconds(40))
                let view = try #require(window.contentView)
                view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
                let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/private/tmp/swiftide-pull-\(name).png"))
            }
        }

        controller.pullReviewed(nil)
        #expect(!controller.remote.isEnabled && !controller.source.isEnabled && !controller.pull.isEnabled)
        try await wait { workspace.operationState == .failed("Denied by server") && workspace.canMutate }
        #expect(controller.source.stringValue == "chosen/new" && controller.review.isEnabled && !controller.pull.isEnabled)
        #expect(await service.writes == 1 && model.submittedPlan?.source == "chosen/new")
    }
}

private actor PullViewsService: GitInspecting, GitMutating, GitPullPlanning {
    private(set) var writes = 0
    private var additionalBranch = false
    func addBranch() { additionalBranch = true }
    private let branch = GitBranch(reference: "refs/heads/main", oid: String(repeating: "a", count: 40), upstream: "refs/remotes/origin/tracked/main")
    func snapshot(at projectRoot: String) async throws -> GitSnapshot { .init(repository: .init(root: "/repo", gitDirectory: "/repo/.git", commonDirectory: "/repo/.git"), branch: "main", head: branch.oid, changes: [], branches: [branch] + (additionalBranch ? [.init(reference: "refs/heads/other", oid: branch.oid)] : []), remotes: ["fork", "origin"]) }
    func history(in repository: GitRepository, revision: String, offset: Int, count: Int) async throws -> GitHistoryPage { .init(commits: [], hasMore: false) }
    func files(in repository: GitRepository, commit: GitCommit) async throws -> [GitCommitFile] { [] }
    func diff(in repository: GitRepository, comparison: GitComparison) async throws -> String { "" }
    func planPull(in snapshot: GitSnapshot, remote: String, source: String) async throws -> GitPullPlan { .init(repository: snapshot.repository, branch: branch, remote: remote, source: source, url: "ssh://git@host/pull.git") }
    func perform(_ action: GitLocalAction, expected: GitSnapshot, output: @escaping @Sendable (String) -> Void) async throws {
        writes += 1; output("Remote denied the pull\n"); throw GitInspectionError.failed("Denied by server")
    }
}
