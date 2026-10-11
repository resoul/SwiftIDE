import AppKit

public extension TablerIcon {
    /// A caller-owned template copy. Control tint supplies the colour in either appearance.
    @MainActor
    func image(accessibilityDescription: String? = nil) -> NSImage {
        guard let result = TablerImageCache.image(for: self).copy() as? NSImage else {
            preconditionFailure("Cannot copy Tabler image")
        }

        result.accessibilityDescription = accessibilityDescription

        return result
    }
}

@MainActor
private enum TablerImageCache {
    static var images: [TablerIcon: NSImage] = [:]

    static func image(for icon: TablerIcon) -> NSImage {
        if let cached = images[icon] { return cached }

        guard let url = Bundle.module.url(forResource: icon.rawValue, withExtension: "pdf"),
              let image = NSImage(contentsOf: url)
        else { preconditionFailure("Missing Tabler vector resource: \(icon.rawValue)") }

        image.isTemplate = true
        image.size = NSSize(width: 24, height: 24)
        images[icon] = image

        return image
    }
}
