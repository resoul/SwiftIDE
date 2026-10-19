import AppKit
import IDEApplication
import WorkspaceUI

/// Owns the palette's floating panel: shows it over the window the user is in, and, when a command
/// is chosen, gives the focus back to that window and performs the command there, so the command
/// reaches the editor or the project the user was working in.
@MainActor
final class CommandPaletteController: NSObject, NSWindowDelegate {
    private final class PalettePanel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    private let catalog: MenuCommandCatalog
    private let menu: () -> NSMenu?
    private let perform: (NSMenuItem) -> Void
    private let content = CommandPaletteViewController()
    private var panel: NSPanel?
    private weak var parent: NSWindow?
    private var entries: [String: NSMenuItem] = [:]
    /// The selector of the menu item that opens the palette, left out of its own list.
    private let opener: Selector

    init(
        catalog: MenuCommandCatalog = MenuCommandCatalog(),
        opener: Selector,
        menu: @escaping () -> NSMenu? = { NSApp.mainMenu },
        perform: @escaping (NSMenuItem) -> Void = { item in
            if let action = item.action { NSApp.sendAction(action, to: item.target, from: item) }
        }
    ) {
        self.catalog = catalog
        self.opener = opener
        self.menu = menu
        self.perform = perform
        super.init()
        content.run = { [weak self] command in self?.choose(command) }
        content.cancel = { [weak self] in self?.dismiss() }
    }

    var isShown: Bool { panel?.isVisible == true }

    func toggle(over window: NSWindow?) {
        isShown ? dismiss() : show(over: window)
    }

    func show(over window: NSWindow?) {
        guard !isShown, let main = menu() else { return }

        let found = catalog.entries(in: main, excluding: opener)
        entries = Dictionary(found.map { ($0.command.id, $0.item) }, uniquingKeysWith: { first, _ in first })
        parent = window
        let panel = self.panel ?? makePanel()
        self.panel = panel
        content.present(found.map(\.command))
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

    private func choose(_ command: PaletteCommand) {
        guard let item = entries[command.id] else { return dismiss() }

        dismiss()
        // After the focus is back in the window the command was chosen for.
        Task { @MainActor [perform] in
            await Task.yield()
            perform(item)
        }
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
        panel.setAccessibilityLabel("Command Palette")

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
