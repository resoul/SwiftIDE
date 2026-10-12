import AppKit
import IDEApplication
import WorkspaceUI

@MainActor
final class GitManagementWindowController: NSWindowController, NSWindowDelegate {
    let content: GitManagementViewController
    var onClosed: (() -> Void)?

    init(workspace: GitWorkspace) {
        content = .init(workspace: workspace)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 730, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Manage Repository"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 660, height: 540)
        window.tabbingMode = .disallowed
        window.contentViewController = content
        super.init(window: window)
        window.delegate = self
        content.close = { [weak self] in self?.dismiss() }
        content.start = { [weak self, weak workspace] plan in
            self?.dismiss()
            workspace?.perform(.manage(plan))
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func present(on parent: NSWindow) { if let window { parent.beginSheet(window) } }

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
