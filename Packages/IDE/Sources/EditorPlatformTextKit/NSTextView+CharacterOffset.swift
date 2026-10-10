import AppKit

public extension NSTextView {
    /// The offset of the character under a point of this view (the point of an event, converted), or
    /// nil if the point is not over a character: past the end of a line, between lines, outside the text.
    @MainActor
    func characterOffset(atViewPoint point: NSPoint) -> Int? {
        guard let window, bounds.contains(point) else { return nil }

        let length = (string as NSString).length
        let nearest = characterIndexForInsertion(at: point)
        // The nearest insertion point is before or after the character the pointer is on.
        for index in [nearest, nearest - 1] where index >= 0 && index < length {
            let screen = firstRect(forCharacterRange: NSRange(location: index, length: 1), actualRange: nil)
            guard !screen.isEmpty else { continue }

            let box = convert(window.convertFromScreen(screen), from: nil)
            if box.insetBy(dx: -0.5, dy: 0).contains(point) { return index }
        }

        return nil
    }
}
