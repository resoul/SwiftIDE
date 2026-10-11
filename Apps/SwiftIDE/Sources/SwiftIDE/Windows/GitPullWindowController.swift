import AppKit
import IDEApplication
import WorkspaceUI

@MainActor
final class GitPullWindowController: NSWindowController, NSWindowDelegate {
    let content: GitPullViewController
    private weak var parent: NSWindow?
    private var temporarilyHidden = false
    private var subscription: UUID?
    private var sheetNotification: NSObjectProtocol?
    var onClosed: (() -> Void)?

    init(workspace: GitWorkspace) {
        content = GitPullViewController(model: GitPullReview(workspace: workspace))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 490), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Pull Branch"; window.isReleasedWhenClosed = false; window.tabbingMode = .disallowed
        window.contentViewController = content
        super.init(window: window); window.delegate = self
        content.close = { [weak self] in self?.dismiss() }
        subscription = workspace.subscribe { [weak self] in self?.updatePresentation() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func present(on parent: NSWindow, remote: String?, source: String?) {
        guard let window else { return }

        self.parent = parent
        sheetNotification = NotificationCenter.default.addObserver(forName: NSWindow.didEndSheetNotification, object: parent, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updatePresentation() }
        }
        content.select(remote: remote, source: source); parent.beginSheet(window)
    }
    private func updatePresentation() {
        guard let window, let parent else { return }

        if content.model.workspace.operationState == .preparing {
            if window.sheetParent === parent {
                temporarilyHidden = true; parent.endSheet(window); window.orderOut(nil)
            }
        } else if temporarilyHidden, parent.isVisible, parent.attachedSheet == nil {
            temporarilyHidden = false; parent.beginSheet(window)
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if content.model.workspace.operationState.isBusy { content.model.workspace.cancelOperation(); return false }
        dismiss(); return false
    }
    func dismiss() {
        if let subscription { content.model.workspace.unsubscribe(subscription) }; subscription = nil
        if let sheetNotification { NotificationCenter.default.removeObserver(sheetNotification) }; sheetNotification = nil
        parent = nil; temporarilyHidden = false
        content.model.stop(); content.disconnect()
        if let window { window.sheetParent?.endSheet(window); window.orderOut(nil) }
        onClosed?()
    }
}
