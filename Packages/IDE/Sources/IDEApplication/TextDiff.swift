import Foundation
import IDEDomain

/// Fallback used only when an editor cannot report exact replacements.
public enum TextDiff {
    /// The smallest single replacement turning `before` into `after`, in UTF-16 units of `before`.
    /// O(n); never splits a surrogate pair. `nil` when the UTF-16 contents are identical.
    public static func singleReplacement(from before: String, to after: String) -> DocumentEdit? {
        let old = Array(before.utf16)
        let new = Array(after.utf16)
        let shortest = min(old.count, new.count)

        var prefix = 0
        while prefix < shortest, old[prefix] == new[prefix] { prefix += 1 }
        if prefix == old.count, prefix == new.count { return nil }
        if prefix > 0, UTF16.isLeadSurrogate(old[prefix - 1]) { prefix -= 1 }

        var suffix = 0
        while suffix < shortest - prefix, old[old.count - 1 - suffix] == new[new.count - 1 - suffix] {
            suffix += 1
        }
        if suffix > 0, UTF16.isTrailSurrogate(old[old.count - suffix]) { suffix -= 1 }

        return DocumentEdit(
            range: UTF16TextRange(location: prefix, length: old.count - prefix - suffix),
            replacement: String(decoding: new[prefix..<(new.count - suffix)], as: UTF16.self)
        )
    }
}

extension DocumentEdit {
    /// Edits (valid, non-overlapping, any order, original coordinates of `source`) that undo
    /// `edits`. The result is expressed in the coordinates of the text after `edits` applied,
    /// ordered by descending position like every committed batch.
    ///
    /// Edits that touch each other (adjacent deletions, an insertion next to a replacement)
    /// leave inverse ranges that touch or share a position, which a batch must not contain.
    /// They are merged into one edit, so the result is always a valid batch.
    public static func inverse(of edits: [DocumentEdit], in source: String) -> [DocumentEdit] {
        let original = source as NSString
        var shift = 0
        var inverse: [DocumentEdit] = []
        for edit in edits.sorted(by: { $0.range.location < $1.range.location }) {
            let replaced = original.substring(
                with: NSRange(location: edit.range.location, length: edit.range.length)
            )
            let length = edit.replacement.utf16.count
            let location = edit.range.location + shift
            shift += length - edit.range.length
            if let last = inverse.last, last.range.location + last.range.length == location {
                inverse[inverse.count - 1] = DocumentEdit(
                    range: UTF16TextRange(location: last.range.location, length: last.range.length + length),
                    replacement: last.replacement + replaced
                )
            } else {
                inverse.append(DocumentEdit(
                    range: UTF16TextRange(location: location, length: length), replacement: replaced
                ))
            }
        }
        return inverse.reversed()
    }
}

extension PreparedDocumentEdit {
    /// Applying these to `resultText` restores `sourceText`.
    public var inverseEdits: [DocumentEdit] { DocumentEdit.inverse(of: edits, in: sourceText) }
}

extension String {
    /// Swift `==` uses canonical equivalence; documents must compare by exact code units.
    func hasSameContents(as other: String) -> Bool {
        utf8.elementsEqual(other.utf8)
    }
}
