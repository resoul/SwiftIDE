import AppKit
import WorkspaceUI

@MainActor
final class SettingsWindowController: NSWindowController {
    let content: SettingsViewController

    init(settings: AppearanceSettings) {
        content = SettingsViewController(appearance: settings.preference)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 190),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.contentViewController = content
        window.center()
        super.init(window: window)
        content.onAppearanceChange = { settings.preference = $0 }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
