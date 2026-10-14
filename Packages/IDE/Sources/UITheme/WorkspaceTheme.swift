import AppKit

/// Shared workspace colours. Change the light/dark values here to restyle every panel.
@MainActor
public enum WorkspaceTheme {
    public static let background = NSColor(name: "org.swiftide.workspace.background") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .black : .white
    }

    public static let folderIcon = NSColor.systemBlue
    public static let swiftFileIcon = NSColor.systemOrange
    public static let sourceFileIcon = NSColor.systemBlue
    public static let configurationFileIcon = NSColor.secondaryLabelColor
    public static let imageFileIcon = NSColor.systemGreen
    public static let fileIcon = NSColor.secondaryLabelColor

    public static let chromeBackground = NSColor(name: "org.swiftide.workspace.chrome") { appearance in
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua

        return NSColor(white: dark ? 0.155 : 0.90, alpha: 1)
    }

    public static func chromeTintOpacity(in appearance: NSAppearance) -> CGFloat {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? 0.24 : 0.14
    }
}
