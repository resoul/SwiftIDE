import Foundation

/// What a line of a Markdown document is, as far as folding and colouring need to know: the lines
/// of fenced code blocks, headings, and everything else. It is a line scan, not a full parser.
public enum MarkdownStructure {
    public enum Kind: Equatable, Sendable {
        case blank
        /// An ATX heading (`# …` to `###### …`) of this level.
        case heading(level: Int)
        /// The line that opens a fenced code block, with its marker (`` ` `` or `~`) and length.
        case fenceOpen(marker: UInt16, length: Int)
        /// The line that closes it.
        case fenceClose
        /// A line inside a fenced code block.
        case code
        case text
    }

    public struct Line: Equatable, Sendable {
        /// The line without its terminator, as UTF-16 offsets.
        public let range: Range<Int>
        /// Where the next line starts (after the terminator).
        public let next: Int
        public let kind: Kind
    }

    public static func lines(in text: [UInt16]) -> [Line] {
        var result: [Line] = []
        var start = 0
        var fence: (marker: UInt16, length: Int)?
        let count = text.count

        while start <= count {
            var end = start
            while end < count, text[end] != 0x0A, text[end] != 0x0D { end += 1 }

            var next = end
            if next < count { next += (text[next] == 0x0D && next + 1 < count && text[next + 1] == 0x0A) ? 2 : 1 }

            // The empty "line" after a final terminator is not a line.
            if start == count, start > 0 { break }

            let kind = classify(text, start..<end, fence: &fence)
            result.append(Line(range: start..<end, next: next, kind: kind))
            if next == end { break }

            start = next
        }

        return result
    }

    private static func classify(
        _ text: [UInt16],
        _ range: Range<Int>,
        fence: inout (marker: UInt16, length: Int)?
    ) -> Kind {
        var index = range.lowerBound
        var indent = 0
        while index < range.upperBound, text[index] == 0x20, indent < 4 {
            index += 1
            indent += 1
        }

        if let open = fence {
            // A closing fence: the same marker, at least as long, and nothing else on the line.
            if indent < 4, run(of: open.marker, in: text, at: index, upTo: range.upperBound) >= open.length,
               isBlank(
                   text,
                   from: index + run(of: open.marker, in: text, at: index, upTo: range.upperBound),
                   to: range.upperBound
               ) {
                fence = nil

                return .fenceClose
            }

            return .code
        }

        if isBlank(text, from: range.lowerBound, to: range.upperBound) { return .blank }

        guard indent < 4, index < range.upperBound else { return .text }

        for marker: UInt16 in [0x60, 0x7E] {
            let length = run(of: marker, in: text, at: index, upTo: range.upperBound)
            guard length >= 3 else { continue }

            // The info string of a backtick fence cannot contain a backtick.
            if marker == 0x60, text[(index + length)..<range.upperBound].contains(0x60) { continue }

            fence = (marker, length)

            return .fenceOpen(marker: marker, length: length)
        }

        if text[index] == 0x23 {
            let level = run(of: 0x23, in: text, at: index, upTo: range.upperBound)
            let after = index + level
            if (1...6).contains(level), after == range.upperBound || text[after] == 0x20 || text[after] == 0x09 {
                return .heading(level: level)
            }
        }

        return .text
    }

    private static func run(of unit: UInt16, in text: [UInt16], at start: Int, upTo end: Int) -> Int {
        var index = start
        while index < end, text[index] == unit { index += 1 }

        return index - start
    }

    private static func isBlank(_ text: [UInt16], from start: Int, to end: Int) -> Bool {
        var index = start
        while index < end {
            if text[index] != 0x20, text[index] != 0x09 { return false }

            index += 1
        }

        return true
    }
}

extension FoldRegions {
    /// The sections and code blocks of a Markdown document. A section runs from its heading to the
    /// line before the next heading of the same or a higher level; a fenced block from its opening
    /// line to the line before its closing fence. The header stays and the lines below it go; for a
    /// section the next heading (or the end of the text) is the first line that stays visible.
    public static func computeMarkdown(in text: [UInt16]) -> [FoldRegion] {
        let lines = MarkdownStructure.lines(in: text)
        var regions: [FoldRegion] = []
        var sections: [(level: Int, line: Int)] = []

        func closeSections(downTo level: Int, at endLine: Int) {
            while let last = sections.last, last.level >= level {
                sections.removeLast()
                emit(startLine: last.line, endLine: endLine)
            }
        }

        func emit(startLine: Int, endLine: Int) {
            // At least one line to hide, and the header must stay.
            guard endLine - startLine >= 2 else { return }

            let hiddenStart = lines[startLine].next
            let hiddenEnd = endLine < lines.count ? lines[endLine].range.lowerBound : text.count
            guard hiddenStart < hiddenEnd else { return }

            regions.append(FoldRegion(
                startLine: startLine,
                headerStart: lines[startLine].range.lowerBound,
                endLine: endLine,
                hidden: hiddenStart..<hiddenEnd
            ))
        }

        var openFence: Int?
        for (index, line) in lines.enumerated() {
            switch line.kind {
            case .heading(let level):
                closeSections(downTo: level, at: index)
                sections.append((level, index))
            case .fenceOpen:
                openFence = index
            case .fenceClose:
                if let open = openFence { emit(startLine: open, endLine: index) }

                openFence = nil
            default:
                break
            }
        }
        // An unclosed fence runs to the end of the text, and so do the sections still open.
        if let open = openFence { emit(startLine: open, endLine: lines.count) }

        closeSections(downTo: 0, at: lines.count)

        return regions.sorted { $0.startLine < $1.startLine }
    }
}
