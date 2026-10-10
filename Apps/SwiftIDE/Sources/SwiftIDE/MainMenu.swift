import AppKit
import IDEDomain

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
            NSMenuItem(title: "Open Folder…", action: #selector(AppDelegate.openFolder(_:)), keyEquivalent: "O"),
            NSMenuItem(title: "Close Opened Folders", action: #selector(AppDelegate.closeOpenedFolders(_:)), keyEquivalent: ""),
            NSMenuItem(title: "Close Project", action: #selector(AppDelegate.closeProject(_:)), keyEquivalent: ""),
            NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"),
            NSMenuItem(title: "Save", action: #selector(WorkspaceWindowController.saveDocument(_:)), keyEquivalent: "s"),
            NSMenuItem(title: "Save As…", action: #selector(WorkspaceWindowController.saveDocumentAs(_:)), keyEquivalent: "S")
        ]))

        main.addItem(submenuItem(title: "Edit", items: [
            NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"),
            NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"),
            .separator(),
            NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"),
            NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"),
            NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"),
            NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"),
            .separator(),
            completeItem(),
            quickHelpItem(),
            jumpToDefinitionItem(),
            goBackItem(),
            languageItem()
        ]))

        main.addItem(submenuItem(title: "Project", items: [
            NSMenuItem(title: "Allow Project Configuration", action: #selector(WorkspaceWindowController.allowProjectConfiguration(_:)), keyEquivalent: ""),
            NSMenuItem(title: "Don't Allow Project Configuration", action: #selector(WorkspaceWindowController.disallowProjectConfiguration(_:)), keyEquivalent: ""),
            .separator(),
            NSMenuItem(title: "Ask About Project Configuration Again", action: #selector(WorkspaceWindowController.askAboutProjectConfigurationAgain(_:)), keyEquivalent: "")
        ]))

        main.addItem(submenuItem(title: "View", items: [
            NSMenuItem(title: "Files", action: #selector(WorkspacePreviewWindowController.showPreviewFiles(_:)), keyEquivalent: "1"),
            NSMenuItem(title: "Search", action: #selector(WorkspacePreviewWindowController.showPreviewSearch(_:)), keyEquivalent: "2"),
            NSMenuItem(title: "Source Control", action: #selector(WorkspacePreviewWindowController.showPreviewSourceControl(_:)), keyEquivalent: "3"),
            NSMenuItem(title: "Terminal", action: #selector(WorkspacePreviewWindowController.showPreviewTerminal(_:)), keyEquivalent: ""),
            NSMenuItem(title: "Assistant", action: #selector(WorkspacePreviewWindowController.showPreviewAssistant(_:)), keyEquivalent: ""),
            .separator(),
            NSMenuItem(title: "Focus Editor", action: #selector(WorkspacePreviewWindowController.toggleFocusEditor(_:)), keyEquivalent: ""),
            NSMenuItem(title: "Reset Layout", action: #selector(WorkspacePreviewWindowController.resetWorkspaceLayout(_:)), keyEquivalent: ""),
            .separator(),
            NSMenuItem(title: "Preview: Light", action: #selector(WorkspacePreviewWindowController.previewLightAppearance(_:)), keyEquivalent: ""),
            NSMenuItem(title: "Preview: Dark", action: #selector(WorkspacePreviewWindowController.previewDarkAppearance(_:)), keyEquivalent: ""),
            NSMenuItem(title: "Preview: System Appearance", action: #selector(WorkspacePreviewWindowController.previewSystemAppearance(_:)), keyEquivalent: "")
        ]))
        main.addItem(submenuItem(title: "Window", items: [
            NSMenuItem(title: "Workspace Preview", action: #selector(AppDelegate.showWorkspacePreview(_:)), keyEquivalent: "")
        ]))
        NSApp.mainMenu = main
    }

    /// Edit ▸ Complete, Control-Space; Escape and F5 do the same in the text view.
    private static func completeItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Complete", action: #selector(NSTextView.complete(_:)), keyEquivalent: " ")
        item.keyEquivalentModifierMask = .control

        return item
    }

    /// Edit ▸ Quick Help, Control-Shift-Space: the description of the symbol at the caret.
    private static func quickHelpItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Quick Help", action: #selector(WorkspaceWindowController.showQuickHelp(_:)), keyEquivalent: " ")
        item.keyEquivalentModifierMask = [.control, .shift]

        return item
    }

    /// Edit ▸ Jump to Definition, Control-Command-J; a Command-click does the same.
    private static func jumpToDefinitionItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Jump to Definition", action: #selector(WorkspaceWindowController.jumpToDefinition(_:)), keyEquivalent: "j")
        item.keyEquivalentModifierMask = [.control, .command]

        return item
    }

    /// Edit ▸ Go Back, Control-Command-Left: to where the last jump to a definition started.
    private static func goBackItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Go Back", action: #selector(AppDelegate.goBack(_:)), keyEquivalent: String(UnicodeScalar(NSLeftArrowFunctionKey)!))
        item.keyEquivalentModifierMask = [.control, .command]

        return item
    }

    /// Edit ▸ Language: Automatic (by the file's name) or one language for this document.
    private static func languageItem() -> NSMenuItem {
        var items = [NSMenuItem(title: "Automatic", action: #selector(WorkspaceWindowController.selectLanguage(_:)), keyEquivalent: "")]
        items.append(.separator())
        for language in DocumentLanguage.allCases {
            let item = NSMenuItem(title: language.displayName, action: #selector(WorkspaceWindowController.selectLanguage(_:)), keyEquivalent: "")
            item.representedObject = language.rawValue
            items.append(item)
        }
        let parent = submenuItem(title: "Language", items: items)
        parent.title = "Language"

        return parent
    }

    private static func submenuItem(title: String, items: [NSMenuItem]) -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: title)
        items.forEach(menu.addItem)
        item.submenu = menu

        return item
    }
}
