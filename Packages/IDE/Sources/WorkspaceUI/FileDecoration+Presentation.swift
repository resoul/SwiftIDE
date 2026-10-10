import AppKit
import IDEApplication

public extension FileNameTone {
    var colour: NSColor {
        switch self {
        case .normal: .labelColor
        case .red: .systemRed
        case .green: .systemGreen
        case .blue: .systemBlue
        case .orange: .systemOrange
        }
    }
}

/// AppKit tabbing keeps each document's original window, responder chain and editor alive.
@MainActor
public enum ProjectDocumentTabs {
    public static func configure(_ window: NSWindow, root: String) {
        window.tabbingIdentifier = "SwiftIDE.project." + root
        window.tabbingMode = .preferred
    }

    public static func append(_ window: NSWindow, to existing: NSWindow) {
        existing.addTabbedWindow(window, ordered: .above)
        if window.tabGroup?.isTabBarVisible == false { window.toggleTabBar(nil) }
        select(window)
    }

    public static func select(_ window: NSWindow) {
        window.tabGroup?.selectedWindow = window
        window.makeKeyAndOrderFront(nil)
    }

    public static func present(_ decoration: FileDecoration, name: String, path: String, in window: NSWindow) {
        let title = name + (decoration.badges.isEmpty ? "" : "  " + decoration.badges)
        window.tab.title = title
        // Let AppKit choose the foreground for ordinary/selected tab labels.
        window.tab.attributedTitle = decoration.tone == .normal ? nil : NSAttributedString(
            string: title,
            attributes: [.foregroundColor: decoration.tone.colour]
        )
        window.tab.toolTip = [path, decoration.explanation].filter { !$0.isEmpty }.joined(separator: "\n")
    }
}
