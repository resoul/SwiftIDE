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

    /// The outer frame keeps the same background and readable controls in either panel theme.
    public static let chromeBackground = NSColor(white: 0.155, alpha: 1)
    public static let chromeTintOpacity: CGFloat = 0.24
    public static let chromeForeground = NSColor.white
    public static let chromeSecondaryForeground = NSColor.white.withAlphaComponent(0.65)
    public static let chromeDisabledForeground = NSColor.white.withAlphaComponent(0.25)
    public static let chromeHoverBackground = NSColor.white.withAlphaComponent(0.12)
}
