import AppKit
import IDEApplication
import WorkspaceUI

/// The command palette: lists the main menu's commands and, when one is chosen, gives the focus
/// back to the window it was opened from and performs the command there, so the command reaches
/// the editor or the project the user was in.
@MainActor
final class CommandPaletteController {
    private let catalog: MenuCommandCatalog
    private let menu: () -> NSMenu?
    private let perform: (NSMenuItem) -> Void
    private let host = PaletteHost(label: "Command Palette")
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
        host.content.run = { [weak self] command in self?.choose(command) }
    }

    var isShown: Bool { host.isShown }

    var window: NSWindow? { host.window }

    var content: CommandPaletteViewController { host.content }

    func toggle(over window: NSWindow?) {
        isShown ? host.dismiss() : show(over: window)
    }

    func show(over window: NSWindow?) {
        guard !isShown, let main = menu() else { return }

        let found = catalog.entries(in: main, excluding: opener)
        entries = Dictionary(found.map { ($0.command.id, $0.item) }, uniquingKeysWith: { first, _ in first })
        host.show(found.map(\.command), over: window)
    }

    private func choose(_ command: PaletteCommand) {
        guard let item = entries[command.id] else { return host.dismiss() }

        host.dismiss()
        // After the focus is back in the window the command was chosen for.
        Task { @MainActor [perform] in
            await Task.yield()
            perform(item)
        }
    }
}
