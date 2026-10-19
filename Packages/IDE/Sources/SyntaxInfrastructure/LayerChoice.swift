import SwiftTreeSitter

/// Which of several grammars colours which part of a document (Objective-C++, ADR-054).
///
/// No grammar reads Objective-C++, so the document is parsed with each candidate. The boundaries
/// are the starts and ends of the top-level nodes of every tree; between two boundaries the grammar
/// whose tree has fewer error units wins (a tie goes to the earlier grammar). A region that no
/// grammar reads stays approximate, and is not hidden.
struct LayerChoice {
    struct Region {
        let range: Range<Int>
        let layer: Int
        /// The grammar still has an error here: where it painted nothing, the others may.
        let isApproximate: Bool
    }

    private var regions: [Region] = []

    init() {}

    /// `trees` are in the order of preference; `length` is the document length in UTF-16 units.
    init(trees: [MutableTree], length: Int, startsWithAt: (Int) -> Bool) {
        guard length > 0 else { return }

        var bounds: Set<Int> = [0, length]
        var errors: [[WeightedRange]] = []
        for tree in trees {
            guard let root = tree.rootNode else {
                errors.append([WeightedRange(range: 0..<length, weight: 1)])
                continue
            }

            Self.addBoundaries(of: root, length: length, to: &bounds)
            errors.append(Self.errorRanges(in: root, length: length, startsWithAt: startsWithAt))
        }

        let costs = errors.map(ErrorCost.init)
        let sorted = bounds.sorted()
        for (from, to) in zip(sorted, sorted.dropFirst()) where from < to {
            var best = 0
            var bestCost = costs[0].cost(from..<to)
            for layer in costs.indices.dropFirst() {
                let cost = costs[layer].cost(from..<to)
                if cost < bestCost {
                    best = layer
                    bestCost = cost
                }
            }
            let approximate = bestCost > 0
            if let last = regions.last, last.layer == best, last.isApproximate == approximate,
               last.range.upperBound == from {
                regions[regions.count - 1] = Region(
                    range: last.range.lowerBound..<to,
                    layer: best,
                    isApproximate: approximate
                )
            } else {
                regions.append(Region(range: from..<to, layer: best, isApproximate: approximate))
            }
        }
    }

    /// The regions that cover `window`, each cut to it.
    func regions(in window: Range<Int>) -> [Region] {
        var low = 0, high = regions.count
        while low < high {
            let mid = (low + high) / 2
            if regions[mid].range.upperBound <= window.lowerBound { low = mid + 1 } else { high = mid }
        }

        var result: [Region] = []
        var index = low
        while index < regions.count, regions[index].range.lowerBound < window.upperBound {
            let range = regions[index].range
            result.append(Region(
                range: max(range.lowerBound, window.lowerBound)..<min(range.upperBound, window.upperBound),
                layer: regions[index].layer,
                isApproximate: regions[index].isApproximate
            ))
            index += 1
        }

        return result
    }

    /// The edges of the top-level nodes, and — where a node holds an error — of its children, a few
    /// levels down, so that one broken method does not decide for the whole class around it.
    private static func addBoundaries(of root: Node, length: Int, to bounds: inout Set<Int>) {
        let maxDepth = 6, maxBounds = 50_000
        var pending: [(node: Node, depth: Int)] = [(root, 0)]
        while let (node, depth) = pending.popLast() {
            for index in 0..<node.childCount {
                guard let child = node.child(at: index) else { continue }

                // An error belongs to the region around it: a boundary at its edge would let the
                // unbroken stretch beside it be judged apart from the error.
                if child.nodeType == "ERROR" || child.isMissing { continue }

                let range = child.byteRange
                bounds.insert(min(length, Int(range.lowerBound) / 2))
                bounds.insert(min(length, Int(range.upperBound) / 2))
                if child.hasError, depth < maxDepth, bounds.count < maxBounds { pending.append((child, depth + 1)) }
            }
        }
    }

    /// Disjoint ranges that hold an error node or a missing one. A stretch of a few units is not the
    /// whole damage: an error discredits the statement around it, or — at the top level — the
    /// declaration after it, so that the unbroken part beside it does not look clean.
    private static func errorRanges(in root: Node, length: Int, startsWithAt: (Int) -> Bool) -> [WeightedRange] {
        func units(_ range: Range<UInt32>) -> Range<Int> {
            min(length, Int(range.lowerBound) / 2)..<min(length, Int(range.upperBound) / 2)
        }

        var raw: [WeightedRange] = []
        var pending: [Node] = [root]
        while let node = pending.popLast() {
            if node.nodeType == "ERROR" || node.isMissing {
                var range = units(node.byteRange)
                let weight = startsWithAt(range.lowerBound) ? Self.directiveWeight : 1
                if let parent = node.parent, let parentType = parent.nodeType, parentType != root.nodeType {
                    range = units(parent.byteRange)
                } else if let next = node.nextSibling {
                    range = range.lowerBound..<max(range.upperBound, units(next.byteRange).upperBound)
                }

                raw.append(WeightedRange(
                    range: range.lowerBound..<max(range.upperBound, range.lowerBound + 1),
                    weight: weight
                ))
            } else if node.hasError {
                for index in 0..<node.childCount {
                    if let child = node.child(at: index) { pending.append(child) }
                }
            }
        }

        var merged: [WeightedRange] = []
        for item in raw.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
            if let last = merged.last, item.range.lowerBound < last.range.upperBound {
                merged[merged.count - 1] = WeightedRange(
                    range: last.range.lowerBound..<max(last.range.upperBound, item.range.upperBound),
                    weight: max(last.weight, item.weight)
                )
            } else {
                merged.append(item)
            }
        }

        return merged
    }

    /// An error that begins with `@` is Objective-C syntax the grammar could not read; it weighs
    /// more than the same stretch of a C++ construct the Objective-C grammar could not read.
    private static let directiveWeight = 64

    private struct WeightedRange {
        let range: Range<Int>
        let weight: Int
    }

    /// The weighted number of error units inside a range, from prefix sums over the sorted ranges.
    private struct ErrorCost {
        private let ranges: [WeightedRange]
        private let prefix: [Int]

        init(_ ranges: [WeightedRange]) {
            self.ranges = ranges
            var sum = 0
            prefix = [0] + ranges.map {
                sum += $0.range.count * $0.weight

                return sum
            }
        }

        func cost(_ range: Range<Int>) -> Int { covered(before: range.upperBound) - covered(before: range.lowerBound) }

        private func covered(before offset: Int) -> Int {
            var low = 0, high = ranges.count
            while low < high {
                let mid = (low + high) / 2
                if ranges[mid].range.lowerBound < offset { low = mid + 1 } else { high = mid }
            }
            guard low > 0 else { return 0 }

            let last = ranges[low - 1]

            return prefix[low - 1] + max(0, min(last.range.upperBound, offset) - last.range.lowerBound) * last.weight
        }
    }
}
