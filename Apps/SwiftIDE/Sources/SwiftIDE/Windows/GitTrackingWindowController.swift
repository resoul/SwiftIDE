import AppKit
import IDEApplication
import WorkspaceUI

@MainActor
final class GitTrackingWindowController: NSWindowController, NSWindowDelegate {
    let content: GitTrackingViewController
    var onClosed: (() -> Void)?

    init(workspace: GitWorkspace) {
        content = GitTrackingViewController(workspace: workspace)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 650, height: 430),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Branch Tracking"
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.contentViewController = content
        super.init(window: window)
        window.delegate = self
        content.close = { [weak self] in self?.dismiss() }
        content.start = { [weak self, weak workspace] plan in
            self?.dismiss()
            workspace?.perform(.tracking(plan))
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func present(on parent: NSWindow, branch: GitBranch?) {
        content.select(branch)
        if let window { parent.beginSheet(window) }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        dismiss()

        return false
    }

    func dismiss() {
        content.disconnect()
        if let window {
            window.sheetParent?.endSheet(window)
            window.orderOut(nil)
        }

        let callback = onClosed
        onClosed = nil
        callback?()
    }
}
