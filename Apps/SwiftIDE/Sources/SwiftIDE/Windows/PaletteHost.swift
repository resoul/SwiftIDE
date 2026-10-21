import AppKit
import IDEApplication
import WorkspaceUI

/// The floating panel a palette lives in: shown over a window, closed when it loses focus, and
/// returning the focus to that window. What the palette lists and what a choice does is its owner's.
@MainActor
final class PaletteHost: NSObject, NSWindowDelegate {
    private final class PalettePanel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    let content = CommandPaletteViewController()
    private var panel: NSPanel?
    private weak var parent: NSWindow?

    private let label: String

    init(label: String) {
        self.label = label
        super.init()
        content.cancel = { [weak self] in self?.dismiss() }
    }

    var isShown: Bool { panel?.isVisible == true }

    /// The panel's window, for tests that look for it.
    var window: NSWindow? { panel }

    func show(_ commands: [PaletteCommand], over window: NSWindow?) {
        guard !isShown else { return }

        parent = window
        let panel = self.panel ?? makePanel()
        self.panel = panel
        content.present(commands)
        position(panel, over: window)
        if let window { window.addChildWindow(panel, ordered: .above) }

        panel.makeKeyAndOrderFront(nil)
        content.focusSearch()
    }

    func dismiss() {
        guard let panel else { return }

        parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        parent?.makeKeyAndOrderFront(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = PalettePanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 340),
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
        panel.contentViewController = content
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.delegate = self
        panel.setAccessibilityLabel(label)

        return panel
    }

    private func position(_ panel: NSPanel, over window: NSWindow?) {
        let size = panel.frame.size
        guard let frame = window?.frame ?? NSScreen.main?.visibleFrame else { return }

        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.maxY - size.height - 90))
    }

    func windowDidResignKey(_ notification: Notification) {
        guard let panel, notification.object as? NSWindow === panel, panel.isVisible else { return }

        parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }
}
