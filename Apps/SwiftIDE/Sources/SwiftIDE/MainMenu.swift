import AppKit

@MainActor
enum MainMenu {
    static func install() {
        let main = NSMenu()
        main.addItem(submenuItem(title: "SwiftIDE", items: [
            NSMenuItem(title: "Quit SwiftIDE", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        ]))
        main.addItem(submenuItem(title: "File", items: [
            NSMenuItem(title: "New", action: #selector(AppDelegate.newDocument(_:)), keyEquivalent: "n"),
            NSMenuItem(title: "Open…", action: #selector(AppDelegate.openDocument(_:)), keyEquivalent: "o"),
            NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"),
            NSMenuItem(title: "Save", action: #selector(WorkspaceWindowController.saveDocument(_:)), keyEquivalent: "s")
        ]))
        main.addItem(submenuItem(title: "Edit", items: [
            NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"),
            NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"),
            .separator(),
            NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"),
            NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"),
            NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"),
            NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        ]))
        NSApp.mainMenu = main
    }

    private static func submenuItem(title: String, items: [NSMenuItem]) -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: title)
        items.forEach(menu.addItem)
        item.submenu = menu
        return item
    }
}
