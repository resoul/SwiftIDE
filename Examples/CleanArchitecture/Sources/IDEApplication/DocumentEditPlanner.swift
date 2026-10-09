import Foundation
import IDEDomain

public enum EditValidationError: Error, Equatable, Sendable {
    case invalidRange
    case splitSurrogatePair
    case overlappingEdits
}

/// A short-lived staged value, not a second authoritative mutable document.
public struct PreparedDocumentEdit: Sendable {
    public let sourceText: String
    public let resultText: String
    public let edits: [DocumentEdit]
}

/// Simple O(document size) planner for this architecture example.
/// A future Piece Tree backend will need a storage-efficient preparation contract.
public enum DocumentEditPlanner {
    public static func prepare(
        _ edits: [DocumentEdit], in text: String
    ) throws -> PreparedDocumentEdit? {
        let units = Array(text.utf16)
        let original = text as NSString
        let ascending = edits.sorted { $0.range.location < $1.range.location }
        var previous: UTF16TextRange?
        var effective: [DocumentEdit] = []

        for edit in ascending {
            let range = edit.range
            guard range.location >= 0, range.length >= 0,
                  range.location <= units.count,
                  range.length <= units.count - range.location else {
                throw EditValidationError.invalidRange
            }
            let end = range.location + range.length
            for boundary in [range.location, end] where boundary > 0 && boundary < units.count {
                if (0xD800...0xDBFF).contains(units[boundary - 1]),
                   (0xDC00...0xDFFF).contains(units[boundary]) {
                    throw EditValidationError.splitSurrogatePair
                }
            }
            if let previous,
               previous.location == range.location || previous.location + previous.length > range.location {
                throw EditValidationError.overlappingEdits
            }
            previous = range
            let replaced = original.substring(with: NSRange(location: range.location, length: range.length))
            if !replaced.utf8.elementsEqual(edit.replacement.utf8) {
                effective.append(edit)
            }
        }

        guard !effective.isEmpty else { return nil }
        let descending = Array(effective.reversed())
        let result = NSMutableString(string: text)
        for edit in descending {
            result.replaceCharacters(
                in: NSRange(location: edit.range.location, length: edit.range.length),
                with: edit.replacement
            )
        }
        let resultText = String(result)
        guard !resultText.utf8.elementsEqual(text.utf8) else { return nil }
        return PreparedDocumentEdit(sourceText: text, resultText: resultText, edits: descending)
    }
}
