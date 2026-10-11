import AppKit
import IDEApplication
import WorkspaceUI

@MainActor
final class GitCloneWindowController: NSWindowController, NSWindowDelegate {
    let content: GitCloneViewController
    var onClosed: (() -> Void)?

    init(model: GitClone) {
        content = GitCloneViewController(model: model)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 440), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Clone Repository"; window.isReleasedWhenClosed = false; window.tabbingMode = .disallowed
        window.contentViewController = content
        super.init(window: window)
        window.delegate = self
        content.close = { [weak self] in self?.dismiss() }
        content.chooseParent = { [weak self] in self?.chooseParent() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func present(on parent: NSWindow) {
        guard let window else { return }

        parent.beginSheet(window); content.focusSource()
    }
    private func chooseParent() {
        guard let window else { return }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.prompt = "Choose Parent Folder"
        panel.beginSheetModal(for: window) { [weak self] response in
            if response == .OK, let path = panel.url?.path { self?.content.parentDirectory = path }
        }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if content.model.state.isBusy { content.model.cancel(); return false }
        dismiss(); return false
    }
    func dismiss() {
        content.model.stop(); content.disconnect()
        if let window { window.sheetParent?.endSheet(window); window.orderOut(nil) }
        onClosed?()
    }
}
