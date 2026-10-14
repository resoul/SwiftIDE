import AppKit

@MainActor
final class WorkspaceWindowToolbar: NSObject, NSToolbarDelegate {
    static let project = NSToolbarItem.Identifier("WorkspaceProject")
    static let detail = NSToolbarItem.Identifier("WorkspaceDetail")
    static let focus = NSToolbarItem.Identifier("WorkspaceFocusEditor")
    static let reset = NSToolbarItem.Identifier("WorkspaceResetLayout")
    let toolbar = NSToolbar(identifier: "WorkspaceWindow")
    private let items: [NSToolbarItem.Identifier: NSToolbarItem]

    init(project: NSView, detail: NSTextField, focus: NSButton, reset: NSButton) {
        var values: [NSToolbarItem.Identifier: NSToolbarItem] = [:]
        for (id, title, view) in [
            (Self.project, "Project", project),
            (Self.detail, "Editor details", detail),
            (Self.focus, "Focus Editor", focus),
            (Self.reset, "Reset Layout", reset)
        ] {
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = title
            item.paletteLabel = title
            item.autovalidates = false
            item.view = view
            if let button = view as? NSButton {
                item.target = button.target
                item.action = button.action
            }

            values[id] = item
        }
        items = values
        super.init()
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        items[Self.project]?.visibilityPriority = .high
        items[Self.detail]?.visibilityPriority = .low
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.project, .flexibleSpace, Self.detail, Self.focus, Self.reset]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        items[itemIdentifier]
    }
}
