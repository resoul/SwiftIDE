import Foundation
import IDEDomain

extension DocumentEdit {
    /// Edits (valid, non-overlapping, any order, in coordinates of the original text) that undo
    /// `edits`, given the text each one replaced. The result is expressed in the coordinates of
    /// the text after `edits` applied, ordered by descending position like every committed batch.
    ///
    /// Edits that touch each other (adjacent deletions, an insertion next to a replacement)
    /// leave inverse ranges that touch or share a position, which a batch must not contain.
    /// They are merged into one edit, so the result is always a valid batch.
    public static func inverse(of edits: [DocumentEdit], replaced: [String]) -> [DocumentEdit] {
        precondition(edits.count == replaced.count)
        var shift = 0
        var inverse: [DocumentEdit] = []
        let ordered = zip(edits, replaced).sorted { $0.0.range.location < $1.0.range.location }
        for (edit, replacedText) in ordered {
            let length = edit.replacement.utf16.count
            let location = edit.range.location + shift
            shift += length - edit.range.length
            if let last = inverse.last, last.range.location + last.range.length == location {
                inverse[inverse.count - 1] = DocumentEdit(
                    range: UTF16TextRange(location: last.range.location, length: last.range.length + length),
                    replacement: last.replacement + replacedText
                )
            } else {
                inverse.append(DocumentEdit(
                    range: UTF16TextRange(location: location, length: length), replacement: replacedText
                ))
            }
        }
        return inverse.reversed()
    }
}

extension String {
    /// Swift `==` uses canonical equivalence; documents must compare by exact code units.
    func hasSameContents(as other: String) -> Bool {
        utf8.elementsEqual(other.utf8)
    }
}
