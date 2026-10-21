import AppKit
import WorkspaceUI

@MainActor
final class SettingsWindowController: NSWindowController {
    let content: SettingsViewController
    private var subscription: UUID?
    private var display: EditorDisplaySettings?

    isolated deinit {
        if let subscription { display?.unsubscribe(subscription) }
    }

    init(settings: AppearanceSettings, display: EditorDisplaySettings) {
        content = SettingsViewController(
            appearance: settings.preference,
            showsTabs: display.showsTabs,
            showsSpaces: display.showsSpaces
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 280),
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
        content.onEditorDisplayChange = { tabs, spaces in
            display.showsTabs = tabs
            display.showsSpaces = spaces
        }
        // Another place (the View menu) may change them while the window is open.
        subscription = display.subscribe { [weak self] in
            self?.content.showsTabs = display.showsTabs
            self?.content.showsSpaces = display.showsSpaces
        }
        self.display = display
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
