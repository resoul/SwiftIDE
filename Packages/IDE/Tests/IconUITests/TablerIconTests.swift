import AppKit
import Testing
import IconUI

@Suite(.serialized) @MainActor
struct TablerIconTests {
    @Test func everyResourceIsVectorAndDrawsAtMultipleSizes() throws {
        _ = NSApplication.shared
        for icon in TablerIcon.allCases {
            let image = icon.image()
            #expect(image.isTemplate)
            #expect(image.size == NSSize(width: 24, height: 24))
            #expect(image.representations.contains { $0 is NSPDFImageRep })
            for size in [16, 24, 48] {
                let bitmap = try #require(NSBitmapImageRep(
                    bitmapDataPlanes: nil,
                    pixelsWide: size,
                    pixelsHigh: size,
                    bitsPerSample: 8,
                    samplesPerPixel: 4,
                    hasAlpha: true,
                    isPlanar: false,
                    colorSpaceName: .deviceRGB,
                    bytesPerRow: 0,
                    bitsPerPixel: 0
                ))
                let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = context
                image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
                NSGraphicsContext.restoreGraphicsState()
                let visible = (0..<size).reduce(0) { total, y in
                    total + (0..<size).filter { (bitmap.colorAt(x: $0, y: y)?.alphaComponent ?? 0) > 0.1 }.count
                }
                #expect(visible > 8, "Blank icon: \(icon.rawValue), \(size)px")
                #expect(visible < size * size / 2, "Lost transparency: \(icon.rawValue)")
            }
        }
    }

    @Test func callerCopiesCannotChangeCachedTemplateOrOtherControls() {
        let first = TablerIcon.folder.image(accessibilityDescription: "First folder")
        first.isTemplate = false
        first.size = NSSize(width: 90, height: 90)
        let second = TablerIcon.folder.image(accessibilityDescription: "Second folder")
        #expect(first !== second)
        #expect(second.isTemplate)
        #expect(second.size == NSSize(width: 24, height: 24))
        #expect(second.accessibilityDescription == "Second folder")
        #expect(first.accessibilityDescription == "First folder")
    }

    @Test func nativeTemplateTintMatchesBothAppearances() throws {
        _ = NSApplication.shared
        for theme in [NSAppearance.Name.aqua, .darkAqua] {
            let gallery = IconGallery(frame: NSRect(x: 0, y: 0, width: 960, height: 288))
            gallery.appearance = NSAppearance(named: theme)
            for (index, icon) in TablerIcon.allCases.enumerated() {
                let x = CGFloat(index % 12) * 80
                let y = CGFloat(index / 12) * 144
                for (row, size) in [16, 24, 32].enumerated() {
                    let image = NSImageView(frame: NSRect(
                        x: x + 24,
                        y: y + CGFloat(row * 40) + 10,
                        width: CGFloat(size),
                        height: CGFloat(size)
                    ))
                    image.image = icon.image()
                    image.contentTintColor = .labelColor
                    image.imageScaling = .scaleProportionallyUpOrDown
                    gallery.addSubview(image)
                }
            }
            let window = NSWindow(contentRect: gallery.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = gallery
            defer { window.close() }
            gallery.layoutSubtreeIfNeeded()
            let bitmap = try #require(gallery.bitmapImageRepForCachingDisplay(in: gallery.bounds))
            gallery.cacheDisplay(in: gallery.bounds, to: bitmap)
            let background = try #require(bitmap.colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB))
            let dark = theme == .darkAqua
            #expect(dark ? background.redComponent < 0.4 : background.redComponent > 0.7)
            let contrasting = (10..<42).reduce(0) { total, y in
                total + (20..<58).filter {
                    guard let colour = bitmap.colorAt(x: $0, y: y)?.usingColorSpace(.deviceRGB) else { return false }

                    return dark ? colour.redComponent > 0.65 : colour.redComponent < 0.35
                }.count
            }
            #expect(contrasting > 10, "Template tint did not follow \(theme.rawValue)")
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: "/private/tmp/swiftide-tabler-\(dark ? "dark" : "light").png"))
        }
    }
}

@MainActor
private final class IconGallery: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
    }
}
