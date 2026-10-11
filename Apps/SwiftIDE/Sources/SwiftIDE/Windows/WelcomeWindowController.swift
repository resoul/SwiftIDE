import AppKit
import IDEApplication
import WorkspaceUI

@MainActor
final class WelcomeWindowController: NSWindowController, NSWindowDelegate {
    let content: WelcomeProjectsViewController
    init(model: RecentProjects) {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Development build"
        content = WelcomeProjectsViewController(model: model, version: version)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 640), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Welcome to SwiftIDE"
        window.minSize = NSSize(width: 760, height: 480)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.contentViewController = content
        super.init(window: window)
        window.delegate = self
        window.center()
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(nil)
        content.focusSearch()
        content.model.refreshAvailability()
    }
    func hide() { window?.orderOut(nil); content.model.stopChecking() }
    func windowWillClose(_ notification: Notification) { content.model.stopChecking() }
}
