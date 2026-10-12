import AppKit
import IDEApplication
import WorkspaceUI

@MainActor
final class GitIntegrationWindowController: NSWindowController, NSWindowDelegate {
    let content: GitIntegrationViewController
    var onClosed: (() -> Void)?

    init(workspace: GitWorkspace, kind: GitIntegrationKind) {
        content = GitIntegrationViewController(workspace: workspace, kind: kind)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 280), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = kind.rawValue.capitalized + " Branch"; window.isReleasedWhenClosed = false; window.tabbingMode = .disallowed
        window.contentViewController = content
        super.init(window: window); window.delegate = self
        content.close = { [weak self] in self?.dismiss() }
        content.start = { [weak self, weak workspace] plan in
            self?.dismiss() // Release the parent before repository-wide save sheets.
            workspace?.perform(.integrate(plan))
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func present(on parent: NSWindow, target: GitBranch?) { content.select(target); if let window { parent.beginSheet(window) } }
    func windowShouldClose(_ sender: NSWindow) -> Bool { dismiss(); return false }
    func dismiss() {
        content.disconnect()
        if let window { window.sheetParent?.endSheet(window); window.orderOut(nil) }
        let callback = onClosed; onClosed = nil; callback?()
    }
}
