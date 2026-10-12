import AppKit
import IDEApplication
import WorkspaceUI

@MainActor
final class GitStashWindowController: NSWindowController, NSWindowDelegate {
    let content: GitStashViewController
    var onClosed: (() -> Void)?

    init(workspace: GitWorkspace) {
        content = GitStashViewController(workspace: workspace)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 650),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Stashes"
        window.minSize = NSSize(width: 650, height: 620)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.contentViewController = content
        super.init(window: window)
        window.delegate = self
        content.close = { [weak self] in self?.dismiss() }
        content.start = { [weak self, weak workspace] plan in
            self?.dismiss()
            workspace?.perform(.stash(plan))
        }
        content.preview = { [weak self, weak workspace] entry in
            self?.dismiss()
            workspace?.inspect(.stash(entry))
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func present(on parent: NSWindow) {
        _ = content.view
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
