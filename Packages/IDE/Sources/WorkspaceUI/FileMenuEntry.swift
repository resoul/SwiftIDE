import AppKit

/// One line of a menu the application fills in for a file: what it says, whether it can be used
/// now and what it does. The menu itself belongs to the view that shows it.
public enum FileMenuEntry {
    case action(title: String, icon: String? = nil, isEnabled: Bool = true, perform: () -> Void)
    case separator
}

/// Carries an entry's closure through `NSMenuItem.representedObject`.
@MainActor
final class FileMenuAction: NSObject {
    let perform: () -> Void

    init(_ perform: @escaping () -> Void) { self.perform = perform }

    @objc func run(_ sender: Any?) { perform() }
}

extension NSMenu {
    /// Adds `entries` to the menu; the items keep their closures alive through their targets.
    @MainActor
    func add(_ entries: [FileMenuEntry]) {
        autoenablesItems = false
        for entry in entries {
            switch entry {
            case .separator:
                if let last = items.last, !last.isSeparatorItem { addItem(.separator()) }
            case .action(let title, let icon, let isEnabled, let perform):
                let target = FileMenuAction(perform)
                let item = NSMenuItem(title: title, action: #selector(FileMenuAction.run(_:)), keyEquivalent: "")
                item.target = target
                item.representedObject = target
                item.isEnabled = isEnabled
                if let icon { item.image = WorkspaceIcon.image(icon, description: nil) }

                addItem(item)
            }
        }

        if items.last?.isSeparatorItem == true { removeItem(at: items.count - 1) }
    }
}
