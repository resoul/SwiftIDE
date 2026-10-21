import AppKit

/// Leaves folded lines out of the layout: a text element (a paragraph) that begins inside one of
/// the hidden ranges is not enumerated, so it has no layout fragment and no height. The text
/// itself is not touched.
@MainActor
final class FoldingContentDelegate: NSObject, @preconcurrency NSTextContentStorageDelegate {
    var ranges: [NSRange] = []
    var offset: ((NSTextLocation) -> Int)?

    func textContentManager(
        _ textContentManager: NSTextContentManager,
        shouldEnumerate textElement: NSTextElement,
        options: NSTextContentManager.EnumerationOptions = []
    ) -> Bool {
        guard !ranges.isEmpty, let range = textElement.elementRange, let offset else { return true }

        let start = offset(range.location)

        return !ranges.contains { start >= $0.location && start < $0.location + $0.length }
    }
}
