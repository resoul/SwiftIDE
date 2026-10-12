import AppKit
import IDEDomain

@MainActor
enum MainMenu {
    static func install() {
        let main = NSMenu()
        main.addItem(submenuItem(title: "SwiftIDE", items: [
            NSMenuItem(title: "Settings…", action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: ","),
            .separator(),
            NSMenuItem(title: "Quit SwiftIDE", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        ]))

        main.addItem(submenuItem(title: "File", items: [
            NSMenuItem(title: "New", action: #selector(AppDelegate.newDocument(_:)), keyEquivalent: "n"),
            NSMenuItem(title: "Open…", action: #selector(AppDelegate.openDocument(_:)), keyEquivalent: "o"),
            NSMenuItem(title: "Open Folder…", action: #selector(AppDelegate.openFolder(_:)), keyEquivalent: "O"),
            NSMenuItem(
                title: "Close Opened Folders",
                action: #selector(AppDelegate.closeOpenedFolders(_:)),
                keyEquivalent: ""
            ),
            NSMenuItem(title: "Close Project", action: #selector(AppDelegate.closeProject(_:)), keyEquivalent: ""),
            NSMenuItem(title: "Close", action: #selector(AppDelegate.closeDocument(_:)), keyEquivalent: "w"),
            NSMenuItem(title: "Save", action: #selector(DocumentEditorController.saveDocument(_:)), keyEquivalent: "s"),
            NSMenuItem(
                title: "Save As…",
                action: #selector(DocumentEditorController.saveDocumentAs(_:)),
                keyEquivalent: "S"
            )
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
            NSMenuItem(
                title: "Allow Project Configuration",
                action: #selector(DocumentEditorController.allowProjectConfiguration(_:)),
                keyEquivalent: ""
            ),
            NSMenuItem(
                title: "Don't Allow Project Configuration",
                action: #selector(DocumentEditorController.disallowProjectConfiguration(_:)),
                keyEquivalent: ""
            ),
            .separator(),
            NSMenuItem(
                title: "Ask About Project Configuration Again",
                action: #selector(DocumentEditorController.askAboutProjectConfigurationAgain(_:)),
                keyEquivalent: ""
            )
        ]))

        main.addItem(submenuItem(title: "Git", items: [
            NSMenuItem(
                title: "GitHub / GitLab…",
                action: #selector(ProjectWorkspaceController.hostingGit(_:)),
                keyEquivalent: ""
            ),
            NSMenuItem(
                title: "Repository Operations…",
                action: #selector(ProjectWorkspaceController.repositoryOperationsGit(_:)),
                keyEquivalent: ""
            ),
            NSMenuItem(
                title: "Manage Repository…",
                action: #selector(ProjectWorkspaceController.manageGit(_:)),
                keyEquivalent: ""
            ),
            NSMenuItem(
                title: "Stashes…",
                action: #selector(ProjectWorkspaceController.stashesGit(_:)),
                keyEquivalent: ""
            ),
            NSMenuItem(
                title: "Branch Tracking…",
                action: #selector(ProjectWorkspaceController.trackingGit(_:)),
                keyEquivalent: ""
            ),
            NSMenuItem(title: "Merge…", action: #selector(ProjectWorkspaceController.mergeGit(_:)), keyEquivalent: ""),
            NSMenuItem(
                title: "Rebase…",
                action: #selector(ProjectWorkspaceController.rebaseGit(_:)),
                keyEquivalent: ""
            ),
            NSMenuItem(
                title: "Interactive Rebase…",
                action: #selector(ProjectWorkspaceController.interactiveRebaseGit(_:)),
                keyEquivalent: ""
            ),
            NSMenuItem(
                title: "Continue Git Operation",
                action: #selector(ProjectWorkspaceController.continueGit(_:)),
                keyEquivalent: ""
            ),
            NSMenuItem(
                title: "Abort Git Operation…",
                action: #selector(ProjectWorkspaceController.abortGit(_:)),
                keyEquivalent: ""
            ),
            NSMenuItem(
                title: "Skip Current Replay…",
                action: #selector(ProjectWorkspaceController.skipGit(_:)),
                keyEquivalent: ""
            ),
            .separator(),
            NSMenuItem(title: "Pull…", action: #selector(ProjectWorkspaceController.pullGit(_:)), keyEquivalent: ""),
            NSMenuItem(title: "Push…", action: #selector(ProjectWorkspaceController.pushGit(_:)), keyEquivalent: ""),
            NSMenuItem(title: "Fetch…", action: #selector(ProjectWorkspaceController.fetchGit(_:)), keyEquivalent: ""),
            NSMenuItem(
                title: "Clone Repository…",
                action: #selector(AppDelegate.cloneRepository(_:)),
                keyEquivalent: ""
            ),
            NSMenuItem(
                title: "Commit Staged…",
                action: #selector(ProjectWorkspaceController.commitGit(_:)),
                keyEquivalent: "k"
            ),
            NSMenuItem(
                title: "Cancel Git Action",
                action: #selector(ProjectWorkspaceController.cancelGit(_:)),
                keyEquivalent: ""
            )
        ]))

        main.addItem(submenuItem(title: "View", items: [
            NSMenuItem(
                title: "Files",
                action: #selector(ProjectWorkspaceController.showFiles(_:)),
                keyEquivalent: "1"
            ),
            NSMenuItem(
                title: "Search",
                action: #selector(ProjectWorkspaceController.showSearch(_:)),
                keyEquivalent: "2"
            ),
            NSMenuItem(
                title: "Source Control",
                action: #selector(ProjectWorkspaceController.showSourceControl(_:)),
                keyEquivalent: "3"
            ),
            NSMenuItem(
                title: "Git Log",
                action: #selector(ProjectWorkspaceController.showGitLog(_:)),
                keyEquivalent: ""
            ),
            NSMenuItem(
                title: "Refresh Git",
                action: #selector(ProjectWorkspaceController.refreshGit(_:)),
                keyEquivalent: ""
            ),
            NSMenuItem(
                title: "Terminal",
                action: #selector(ProjectWorkspaceController.showTerminal(_:)),
                keyEquivalent: ""
            ),
            NSMenuItem(
                title: "Assistant",
                action: #selector(ProjectWorkspaceController.showAssistant(_:)),
                keyEquivalent: ""
            ),
            .separator(),
            NSMenuItem(
                title: "Focus Editor",
                action: #selector(ProjectWorkspaceController.toggleFocusEditor(_:)),
                keyEquivalent: ""
            ),
            fullScreenItem(),
            NSMenuItem(
                title: "Reset Layout",
                action: #selector(ProjectWorkspaceController.resetWorkspaceLayout(_:)),
                keyEquivalent: ""
            )
        ]))
        main.addItem(submenuItem(title: "Window", items: [
            NSMenuItem(title: "Welcome", action: #selector(AppDelegate.showWelcome(_:)), keyEquivalent: "")
        ]))
        NSApp.mainMenu = main
    }

    private static func fullScreenItem() -> NSMenuItem {
        let item = NSMenuItem(
            title: "Toggle Full Screen",
            action: #selector(NSWindow.toggleFullScreen(_:)),
            keyEquivalent: "f"
        )
        item.keyEquivalentModifierMask = [.control, .command]

        return item
    }

    /// Edit ▸ Complete, Control-Space; Escape and F5 do the same in the text view.
    private static func completeItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Complete", action: #selector(NSTextView.complete(_:)), keyEquivalent: " ")
        item.keyEquivalentModifierMask = .control

        return item
    }

    /// Edit ▸ Quick Help, Control-Shift-Space: the description of the symbol at the caret.
    private static func quickHelpItem() -> NSMenuItem {
        let item = NSMenuItem(
            title: "Quick Help",
            action: #selector(DocumentEditorController.showQuickHelp(_:)),
            keyEquivalent: " "
        )
        item.keyEquivalentModifierMask = [.control, .shift]

        return item
    }

    /// Edit ▸ Jump to Definition, Control-Command-J; a Command-click does the same.
    private static func jumpToDefinitionItem() -> NSMenuItem {
        let item = NSMenuItem(
            title: "Jump to Definition",
            action: #selector(DocumentEditorController.jumpToDefinition(_:)),
            keyEquivalent: "j"
        )
        item.keyEquivalentModifierMask = [.control, .command]

        return item
    }

    /// Edit ▸ Go Back, Control-Command-Left: to where the last jump to a definition started.
    private static func goBackItem() -> NSMenuItem {
        let item = NSMenuItem(
            title: "Go Back",
            action: #selector(AppDelegate.goBack(_:)),
            keyEquivalent: String(UnicodeScalar(NSLeftArrowFunctionKey)!)
        )
        item.keyEquivalentModifierMask = [.control, .command]

        return item
    }

    /// Edit ▸ Language: Automatic (by the file's name) or one language for this document.
    private static func languageItem() -> NSMenuItem {
        var items = [NSMenuItem(
            title: "Automatic",
            action: #selector(DocumentEditorController.selectLanguage(_:)),
            keyEquivalent: ""
        )]
        items.append(.separator())
        for language in DocumentLanguage.allCases {
            let item = NSMenuItem(
                title: language.displayName,
                action: #selector(DocumentEditorController.selectLanguage(_:)),
                keyEquivalent: ""
            )
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
