import Foundation
import IDEDomain

/// The word (letters, digits, underscore, anything beyond ASCII) around an offset.
public enum WordRange {
    /// `text` gives the text of a range; `length` is the length of the document. Nil if the
    /// character at `offset` is not part of a word. A word is read at most 128 units either way.
    @MainActor
    public static func around(_ offset: Int, length: Int, text: (UTF16TextRange) -> String) -> UTF16TextRange? {
        guard offset >= 0, offset < length else { return nil }

        let from = max(0, offset - 128), to = min(length, offset + 129)
        let units = Array(text(UTF16TextRange(location: from, length: to - from)).utf16)
        let at = offset - from
        guard at < units.count, CompletionController.isWordUnit(units[at]) else { return nil }

        var start = at, end = at + 1
        while start > 0, CompletionController.isWordUnit(units[start - 1]) { start -= 1 }
        while end < units.count, CompletionController.isWordUnit(units[end]) { end += 1 }

        return UTF16TextRange(location: from + start, length: end - start)
    }
}
