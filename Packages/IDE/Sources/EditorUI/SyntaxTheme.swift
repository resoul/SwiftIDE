import AppKit
import IDEDomain

@MainActor
public struct SyntaxTheme {
    private let colours: [HighlightKind: NSColor]

    public init(colours: [HighlightKind: NSColor]) {
        self.colours = colours
    }

    /// The colour of a kind, or nil to leave the text in its ordinary colour.
    public func colour(for kind: HighlightKind) -> NSColor? { colours[kind] }

    private static func dynamic(light: (CGFloat, CGFloat, CGFloat), dark: (CGFloat, CGFloat, CGFloat)) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let (r, g, b) = isDark ? dark : light

            return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
        }
    }

    public static var standard: SyntaxTheme { SyntaxTheme(colours: [
        .keyword: dynamic(light: (0.68, 0.14, 0.60), dark: (0.99, 0.37, 0.64)),
        .builtin: dynamic(light: (0.68, 0.14, 0.60), dark: (0.99, 0.37, 0.64)),
        .string: dynamic(light: (0.77, 0.10, 0.09), dark: (0.99, 0.41, 0.36)),
        .escape: dynamic(light: (0.55, 0.20, 0.55), dark: (0.85, 0.55, 0.95)),
        .number: dynamic(light: (0.11, 0.00, 0.81), dark: (0.82, 0.75, 0.40)),
        .comment: dynamic(light: (0.36, 0.42, 0.47), dark: (0.50, 0.55, 0.60)),
        .documentation: dynamic(light: (0.20, 0.45, 0.30), dark: (0.45, 0.70, 0.55)),
        .type: dynamic(light: (0.04, 0.38, 0.45), dark: (0.36, 0.80, 0.88)),
        .function: dynamic(light: (0.12, 0.25, 0.72), dark: (0.42, 0.58, 1.00)),
        .property: dynamic(light: (0.33, 0.42, 0.06), dark: (0.64, 0.85, 0.42)),
        .constant: dynamic(light: (0.45, 0.20, 0.68), dark: (0.74, 0.60, 1.00)),
        .attribute: dynamic(light: (0.50, 0.30, 0.10), dark: (0.90, 0.65, 0.40)),
        .label: dynamic(light: (0.40, 0.40, 0.10), dark: (0.80, 0.80, 0.45))
        // Operators, parameters and everything else stay in the text colour.
    ]) }
}
