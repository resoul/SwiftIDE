import AppKit
import IDEApplication
import WorkspaceUI

@MainActor
final class GitInteractiveRebaseWindowController: NSWindowController, NSWindowDelegate {
    let content: GitInteractiveRebaseViewController
    var onClosed: (() -> Void)?

    init(workspace: GitWorkspace) {
        content = .init(model: .init(workspace: workspace))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Interactive Rebase"
        window.minSize = NSSize(width: 680, height: 500)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.contentViewController = content
        super.init(window: window)
        window.delegate = self
        content.close = { [weak self] in self?.dismiss() }
        content.start = { [weak self, weak workspace] plan in
            guard let self, let window = self.window else { return }

            let alert = NSAlert()
            alert.messageText = "Rewrite the reviewed history?"
            alert.informativeText = plan.source.repository.root + "\nBranch: " + plan.source.branch
                + "\nHEAD: " + plan.source.head + "\nOnto: " + plan.source.target.oid
                + """
                \nCommits: \(plan.steps.count); explicitly dropped: \
                \(plan.steps.filter { $0.action == .drop }.count)
                """
                + """
                \nSquash uses combined messages. Fixup keeps the preceding message. Edit pauses for changes. No \
                Push.
                """
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Rebase")
            alert.beginSheetModal(for: window) { [weak self, weak workspace] response in
                guard response == .alertSecondButtonReturn, self?.content.model.plan == plan,
                      self?.content.model.canApply == true else { return }

                self?.dismiss()
                workspace?.perform(.interactiveRebase(plan))
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func present(on parent: NSWindow) {
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
