import AppKit
import IDEApplication

/// The palette's commands, read from the main menu: the menu is the one list of commands, so the
/// titles, shortcuts and availability the palette shows are the ones the menu bar has.
@MainActor
struct MenuCommandCatalog {
    struct Entry {
        let command: PaletteCommand
        let item: NSMenuItem
    }

    /// Whether `item` can be performed now. Defaults to the responder chain's own answer.
    var isAvailable: @MainActor (NSMenuItem) -> Bool = MenuCommandCatalog.respondsAndValidates

    /// Every command under `menu` that has an action, in menu order. `excluding` leaves out the
    /// command that opens the palette itself.
    func entries(in menu: NSMenu, excluding: Selector? = nil) -> [Entry] {
        var found: [Entry] = []
        collect(menu, path: [], prefix: "", excluding: excluding, into: &found)

        return found
    }

    private func collect(
        _ menu: NSMenu,
        path: [String],
        prefix: String,
        excluding: Selector?,
        into found: inout [Entry]
    ) {
        for (index, item) in menu.items.enumerated() where !item.isSeparatorItem && !item.isHidden {
            let id = prefix + "\(index)"
            if let submenu = item.submenu {
                collect(submenu, path: path + [item.title], prefix: id + ".", excluding: excluding, into: &found)
            } else if let action = item.action, action != excluding, !item.title.isEmpty {
                found.append(Entry(
                    command: PaletteCommand(
                        id: id,
                        title: item.title,
                        group: path.joined(separator: " ▸ "),
                        shortcut: Self.shortcut(of: item),
                        isEnabled: isAvailable(item)
                    ),
                    item: item
                ))
            }
        }
    }

    static func respondsAndValidates(_ item: NSMenuItem) -> Bool {
        guard let action = item.action,
              let target = NSApp.target(forAction: action, to: item.target, from: item) else { return false }

        if let validator = target as? NSMenuItemValidation { return validator.validateMenuItem(item) }

        if let validator = target as? NSUserInterfaceValidations { return validator.validateUserInterfaceItem(item) }

        return true
    }

    /// "⇧⌘P" for Command-Shift-P. A capital letter in a key equivalent means Shift is held.
    static func shortcut(of item: NSMenuItem) -> String? {
        let key = item.keyEquivalent
        guard !key.isEmpty else { return nil }

        var modifiers = item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask)
        if key.count == 1, key.first?.isUppercase == true { modifiers.insert(.shift) }

        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        switch key {
        case " ": text += "Space"
        case "\r": text += "↩"
        case "\u{1B}": text += "⎋"
        default: text += key.uppercased()
        }

        return text
    }
}
