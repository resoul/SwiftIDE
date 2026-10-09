import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let composition = AppCompositionRoot()
    private var windows: [WorkspaceWindowController] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainMenu.install()
        newDocument(nil)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    @objc func newDocument(_ sender: Any?) {
        let controller = composition.makeWorkspaceWindow()
        windows.append(controller)
        controller.showWindow(nil)
    }
}
