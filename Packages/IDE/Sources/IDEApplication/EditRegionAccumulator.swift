import IDEDomain

/// Folds several storage passes of one input operation into the one region they changed.
///
/// Each pass is described the way text storage reports it: the range that now holds new text
/// (`editedRange`, in coordinates after the pass) and by how much the length changed. The hull of
/// all passes is the smallest region that covers every change; replacing `rangeBefore` of the
/// original text with the text found at `rangeAfter` of the final text turns one into the other.
/// It may include characters that did not change, never the reverse.
public struct EditRegionAccumulator: Equatable, Sendable {
    public private(set) var isEmpty = true
    private var start = 0
    private var end = 0
    private var delta = 0

    public init() {}

    public mutating func record(editedRange: UTF16TextRange, changeInLength: Int) {
        let location = editedRange.location
        let newEnd = location + editedRange.length
        // The pass replaced [location, oldEnd) of the previous text by [location, newEnd).
        let oldEnd = newEnd - changeInLength
        if isEmpty {
            start = location
            end = newEnd
            isEmpty = false
        } else {
            // Where the hull's edges are after the pass; an edge inside the replaced part moves to
            // the edge of the new text.
            let mappedStart = start <= location ? start : (start >= oldEnd ? start + changeInLength : location)
            let mappedEnd = end <= location ? end : (end >= oldEnd ? end + changeInLength : newEnd)
            start = min(mappedStart, location)
            end = max(mappedEnd, newEnd)
        }
        delta += changeInLength
    }

    /// The region in coordinates of the text before the first recorded pass.
    public var rangeBefore: UTF16TextRange {
        UTF16TextRange(location: start, length: end - start - delta)
    }

    /// The same region in coordinates of the text after the last recorded pass.
    public var rangeAfter: UTF16TextRange {
        UTF16TextRange(location: start, length: end - start)
    }

    public func isInside(_ range: UTF16TextRange) -> Bool {
        !isEmpty && start >= range.location && end <= range.location + range.length
    }
}
