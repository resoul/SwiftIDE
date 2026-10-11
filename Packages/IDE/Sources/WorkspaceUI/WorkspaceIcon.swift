import AppKit
import IconUI

/// Preserves custom SF Symbol tools and supports `tabler:brand-docker` without changing layout archives.
@MainActor
enum WorkspaceIcon {
    static func image(_ name: String, description: String? = nil) -> NSImage? {
        if name.hasPrefix("tabler:") {
            return TablerIcon(rawValue: String(name.dropFirst(7)))?.image(accessibilityDescription: description)
        }

        let icon: TablerIcon? = switch name {
        case "folder", "folder.fill": .folder
        case "folder.badge.questionmark": .folderSymlink
        case "swift": .brandSwift
        case "doc.text": .file
        case "gearshape": .settings
        case "magnifyingglass": .search
        case "arrow.triangle.branch": .gitBranch
        case "terminal": .terminal2
        case "hammer": .hammer
        case "exclamationmark.circle": .alertCircle
        case "bubble.left.and.bubble.right": .messages
        case "list.bullet.indent": .listTree
        case "slider.horizontal.3": .adjustmentsHorizontal
        case "chevron.down": .chevronDown
        case "minus": .minus
        case "xmark": .x
        default: nil
        }

        return icon?.image(accessibilityDescription: description)
            ?? NSImage(systemSymbolName: name, accessibilityDescription: description)
    }
}
