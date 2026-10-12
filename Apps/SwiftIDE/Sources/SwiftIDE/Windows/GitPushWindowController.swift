import AppKit
import IDEApplication
import WorkspaceUI

@MainActor
final class GitPushWindowController: NSWindowController, NSWindowDelegate {
    let content: GitPushViewController
    var onClosed: (() -> Void)?

    init(workspace: GitWorkspace) {
        content = GitPushViewController(model: GitPushReview(workspace: workspace))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 660, height: 490),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Push Branch"
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.contentViewController = content
        super.init(window: window)
        window.delegate = self
        content.close = { [weak self] in self?.dismiss() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func present(on parent: NSWindow, branch: String?, remote: String?) {
        guard let window else { return }

        content.select(branch: branch, remote: remote)
        parent.beginSheet(window)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if content.model.workspace.operationState.isBusy {
            content.model.workspace.cancelOperation()

            return false
        }

        dismiss()

        return false
    }

    func dismiss() {
        content.model.stop()
        content.disconnect()
        if let window {
            window.sheetParent?.endSheet(window)
            window.orderOut(nil)
        }

        onClosed?()
    }
}
