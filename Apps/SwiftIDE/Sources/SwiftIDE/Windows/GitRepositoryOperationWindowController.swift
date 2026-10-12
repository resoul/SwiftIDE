import AppKit
import IDEApplication
import WorkspaceUI

@MainActor
final class GitRepositoryOperationWindowController: NSWindowController, NSWindowDelegate {
    let content: GitRepositoryOperationViewController
    var onClosed: (() -> Void)?

    init(workspace: GitWorkspace) {
        content = .init(model: .init(workspace: workspace))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Repository Operations"
        window.minSize = NSSize(width: 680, height: 460)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.contentViewController = content
        super.init(window: window)
        window.delegate = self
        content.close = { [weak self] in self?.dismiss() }
        content.start = { [weak self, weak workspace] plan in
            guard let self, let window = self.window else { return }

            let alert = NSAlert()
            alert.messageText = plan.request.kind.rawValue + "?"
            alert.informativeText = plan.summary
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Apply reviewed operation")
            alert.beginSheetModal(for: window) { [weak self, weak workspace] response in
                guard response == .alertSecondButtonReturn, self?.content.model.plan == plan,
                      self?.content.model.canApply == true else { return }

                self?.dismiss()
                workspace?.perform(.repositoryOperation(plan))
            }
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
