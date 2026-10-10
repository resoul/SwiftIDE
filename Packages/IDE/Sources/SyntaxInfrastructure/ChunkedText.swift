import Foundation

struct ChunkedText {
    private static let target = 16_384

    private var chunks: [[UInt16]] = []
    private var starts: [Int] = []

    private(set) var length = 0

    init() {}

    init(chunks incoming: [[UInt16]]) {
        for chunk in incoming where !chunk.isEmpty {
            for piece in Self.split(chunk) { chunks.append(piece) }
        }
        recomputeStarts(from: 0)
    }

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

    func bytes(fromUnit unit: Int) -> Data? {
        guard unit >= 0, unit < length else { return nil }
        let index = chunkIndex(containing: unit)
        let chunk = chunks[index]
        let from = unit - starts[index]
        return chunk[from...].withUnsafeBufferPointer { Data(buffer: $0) }
    }

    func forEachPair(_ first: UInt16, _ second: UInt16, _ body: (Int) -> Bool) {
        var carried = false
        for (index, chunk) in chunks.enumerated() {
            let start = starts[index]
            if carried, chunk.first == second, !body(start - 1) { return }
            var stopped = false
            chunk.withUnsafeBufferPointer { units in
                var position = 0
                while position + 1 < units.count {
                    if units[position] == first, units[position + 1] == second, !body(start + position) {
                        stopped = true
                        return
                    }
                    position += 1
                }
            }
            if stopped { return }
            carried = chunk.last == first
        }
    }

    var units: [UInt16] { chunks.flatMap { $0 } }

    var chunkCount: Int { chunks.count }

    // MARK: Structure

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
