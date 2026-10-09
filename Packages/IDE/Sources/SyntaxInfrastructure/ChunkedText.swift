import Foundation

/// UTF-16 text in chunks of a few thousand units, so an edit moves one or two chunks instead of the
/// document and the parser can read straight from the pieces.
struct ChunkedText {
    private static let target = 16_384

    private var chunks: [[UInt16]] = []
    /// Offset of the first unit of each chunk.
    private var starts: [Int] = []
    private(set) var length = 0

    init() {}

    init(chunks incoming: [[UInt16]]) {
        for chunk in incoming where !chunk.isEmpty {
            for piece in Self.split(chunk) { chunks.append(piece) }
        }
        recomputeStarts(from: 0)
    }

    /// Replaces `range` with `units`. Returns false, changing nothing, if the range does not fit.
    @discardableResult
    mutating func replace(_ range: Range<Int>, with units: [UInt16]) -> Bool {
        guard range.lowerBound >= 0, range.upperBound <= length else { return false }
        guard !(range.isEmpty && units.isEmpty) else { return true }
        if chunks.isEmpty {
            chunks = Self.split(units)
            recomputeStarts(from: 0)
            return true
        }
        let first = chunkIndex(containing: range.lowerBound)
        let last = chunkIndex(containing: range.upperBound)
        var combined = Array(chunks[first][..<(range.lowerBound - starts[first])])
        combined.append(contentsOf: units)
        combined.append(contentsOf: chunks[last][(range.upperBound - starts[last])...])
        chunks.replaceSubrange(first...last, with: Self.split(combined))
        recomputeStarts(from: first)
        return true
    }

    func substring(_ range: Range<Int>) -> String {
        guard range.lowerBound >= 0, range.upperBound <= length, !range.isEmpty else { return "" }
        var units: [UInt16] = []
        units.reserveCapacity(range.count)
        var index = chunkIndex(containing: range.lowerBound)
        var position = range.lowerBound
        while position < range.upperBound, index < chunks.count {
            let chunk = chunks[index]
            let from = position - starts[index]
            let to = min(chunk.count, range.upperBound - starts[index])
            units.append(contentsOf: chunk[from..<to])
            position = starts[index] + to
            index += 1
        }
        return String(decoding: units, as: UTF16.self)
    }

    /// The text from unit `unit` to the end of its chunk, as UTF-16 little-endian bytes: what the
    /// parser reads. Nil at the end of the text.
    func bytes(fromUnit unit: Int) -> Data? {
        guard unit >= 0, unit < length else { return nil }
        let index = chunkIndex(containing: unit)
        let chunk = chunks[index]
        let from = unit - starts[index]
        return chunk[from...].withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// All the text. For tests and small inputs.
    var units: [UInt16] { chunks.flatMap { $0 } }

    var chunkCount: Int { chunks.count }

    // MARK: Structure

    /// The chunk holding `offset`; the end of the text belongs to the last chunk.
    private func chunkIndex(containing offset: Int) -> Int {
        var low = 0, high = chunks.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if starts[middle] <= offset { low = middle } else { high = middle - 1 }
        }
        return low
    }

    private static func split(_ units: [UInt16]) -> [[UInt16]] {
        guard !units.isEmpty else { return [] }
        if units.count <= target * 2 { return [units] }
        return stride(from: 0, to: units.count, by: target).map {
            Array(units[$0..<min($0 + target, units.count)])
        }
    }

    private mutating func recomputeStarts(from index: Int) {
        if index == 0 { starts = [] } else { starts.removeSubrange(index...) }
        var offset = index == 0 ? 0 : starts[index - 1] + chunks[index - 1].count
        for position in index..<chunks.count {
            starts.append(offset)
            offset += chunks[position].count
        }
        length = offset
    }
}
