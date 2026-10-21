import Foundation
import IDEApplication
import IDEDomain

/// The colours of a Markdown document, from its lines and a handful of inline patterns. It is not a
/// Markdown parser: it colours what is recognisable at a glance (headings, emphasis, code, links,
/// quotes, lists, rules, HTML comments, tables) and leaves the rest as text.
enum MarkdownColours {
    /// A kind for every UTF-16 unit of `text` (0 is "no colour").
    static func kinds(for text: [UInt16]) -> [UInt8] {
        var kinds = [UInt8](repeating: 0, count: text.count)
        guard !text.isEmpty else { return kinds }

        let source = String(decoding: text, as: UTF16.self)
        let lines = MarkdownStructure.lines(in: text)
        var previousWasParagraph = false
        var previous: MarkdownStructure.Line?

        func paint(_ range: Range<Int>, _ kind: HighlightKind) {
            for index in max(0, range.lowerBound)..<min(text.count, range.upperBound) { kinds[index] = kind.rawValue }
        }

        for line in lines {
            let range = line.range
            switch line.kind {
            case .blank:
                previousWasParagraph = false
            case .heading:
                paint(range, .keyword)
                previousWasParagraph = false
            case .fenceOpen(let marker, let length):
                paint(range, .attribute)
                // The info string after the marker names the language.
                let info = range.lowerBound + leadingSpaces(text, range) + length
                if info < range.upperBound { paint(info..<range.upperBound, .label) }

                _ = marker
                previousWasParagraph = false
            case .fenceClose:
                paint(range, .attribute)
                previousWasParagraph = false
            case .code:
                paint(range, .string)
                previousWasParagraph = false
            case .text:
                if let rule = thematicBreakOrSetextUnderline(text, range) {
                    // A line of "===" or "---" under a paragraph line makes that line a heading.
                    if rule.isSetext, previousWasParagraph, let previous {
                        paint(previous.range, .keyword)
                        paint(range, .keyword)
                    } else if rule.isBreak {
                        paint(range, .operator)
                    }

                    previousWasParagraph = false
                    previous = line
                    continue
                }

                inline(text, source, range, &kinds)
                previousWasParagraph = !startsBlock(text, range)
            }
            previous = line
        }

        htmlComments(source, lines: lines, &kinds)

        return kinds
    }

    // MARK: Blocks

    private static func leadingSpaces(_ text: [UInt16], _ range: Range<Int>) -> Int {
        var count = 0
        while range.lowerBound + count < range.upperBound, text[range.lowerBound + count] == 0x20, count < 3 {
            count += 1
        }

        return count
    }

    /// Whether the line is a list item or a quote, which are not paragraph text a rule could underline.
    private static func startsBlock(_ text: [UInt16], _ range: Range<Int>) -> Bool {
        var index = range.lowerBound + leadingSpaces(text, range)
        guard index < range.upperBound else { return false }

        if text[index] == 0x3E { return true }

        if [0x2D, 0x2B, 0x2A].contains(text[index]), index + 1 < range.upperBound, text[index + 1] == 0x20 {
            return true
        }

        let digitsStart = index
        while index < range.upperBound, text[index] >= 0x30, text[index] <= 0x39 { index += 1 }

        return index > digitsStart && index - digitsStart <= 9 && index + 1 < range.upperBound
            && (text[index] == 0x2E || text[index] == 0x29) && text[index + 1] == 0x20
    }

    private static func thematicBreakOrSetextUnderline(
        _ text: [UInt16],
        _ range: Range<Int>
    ) -> (isBreak: Bool, isSetext: Bool)? {
        var index = range.lowerBound + leadingSpaces(text, range)
        guard index < range.upperBound else { return nil }

        let mark = text[index]
        guard [0x2D, 0x2A, 0x5F, 0x3D].contains(mark) else { return nil }

        var count = 0
        var onlyMark = true
        while index < range.upperBound {
            let unit = text[index]
            if unit == mark { count += 1 } else if unit != 0x20, unit != 0x09 { return nil } else if unit == 0x20 {
                onlyMark = false
            }

            index += 1
        }

        // "===" and a plain "---" or "***" run can underline a paragraph; "- - -" and "***" with
        // spaces between are rules only. Three or more of a rule mark make a rule.
        let isBreak = mark != 0x3D && count >= 3
        let isSetext = onlyMark && (mark == 0x3D || mark == 0x2D) && count >= 1

        return isBreak || isSetext ? (isBreak, isSetext) : nil
    }

    // MARK: Inline

    private struct Pattern {
        let expression: NSRegularExpression
        let paints: [(group: Int, kind: HighlightKind)]

        init(_ pattern: String, _ paints: [(Int, HighlightKind)]) {
            expression = try! NSRegularExpression(pattern: pattern)
            self.paints = paints
        }
    }

    // Lowest priority first: a later pattern paints over an earlier one.
    private static let patterns: [Pattern] = [
        Pattern(#"(?<![\*\w])(\*|_)(?=\S)(?:(?!\1).)+?(?<=\S)\1(?![\*\w])"#, [(0, .builtin)]),
        Pattern(#"(\*\*|__)(?=\S)(?:(?!\1).)+?(?<=\S)\1"#, [(0, .builtin)]),
        Pattern(#"~~(?=\S).+?(?<=\S)~~"#, [(0, .comment)]),
        Pattern(#"https?://[^\s<>\)\]]+"#, [(0, .constant)]),
        Pattern(#"<(?:https?://|mailto:)[^>\s]+>"#, [(0, .constant)]),
        Pattern(#"!?(\[[^\]\n]*\])(\([^)\n]*\)|\[[^\]\n]*\])"#, [(1, .function), (2, .constant)]),
        Pattern(#"^\s{0,3}\[[^\]\n]+\]:\s*\S+"#, [(0, .constant)]),
        Pattern(#"\\[\\`*_{}\[\]()#+\-.!|>~<]"#, [(0, .escape)]),
        Pattern(#"(`+)(?!`).+?(?<!`)\1(?!`)"#, [(0, .string)])
    ]

    private static func inline(_ text: [UInt16], _ source: String, _ range: Range<Int>, _ kinds: inout [UInt8]) {
        var content = range
        // Block markers first: quote marks, list bullets and numbers, task boxes, table pipes.
        var index = range.lowerBound + leadingSpaces(text, range)
        while index < range.upperBound, text[index] == 0x3E {
            kinds[index] = HighlightKind.operator.rawValue
            index += 1
            while index < range.upperBound, text[index] == 0x20 { index += 1 }

            content = index..<range.upperBound
        }

        let listStart = content.lowerBound + leadingSpaces(text, content.lowerBound..<content.upperBound)
        if startsBlock(text, listStart..<content.upperBound), listStart < content.upperBound, text[listStart] != 0x3E {
            var end = listStart
            while end < content.upperBound, text[end] != 0x20 { end += 1 }

            for position in listStart..<end { kinds[position] = HighlightKind.operator.rawValue }

            content = min(end + 1, content.upperBound)..<content.upperBound
            // A task box: "[ ]" or "[x]".
            if content.count >= 3, text[content.lowerBound] == 0x5B, text[content.lowerBound + 2] == 0x5D,
               [0x20, 0x78, 0x58].contains(text[content.lowerBound + 1]) {
                for position in content.lowerBound..<(content.lowerBound + 3) {
                    kinds[position] = HighlightKind.constant.rawValue
                }
            }
        }

        guard !content.isEmpty else { return }

        for pattern in patterns {
            pattern.expression.enumerateMatches(
                in: source,
                options: [],
                range: NSRange(location: content.lowerBound, length: content.count)
            ) { match, _, _ in
                guard let match else { return }

                for paint in pattern.paints {
                    let found = match.range(at: paint.group)
                    guard found.location != NSNotFound else { continue }

                    for position in found.location..<(found.location + found.length) {
                        kinds[position] = paint.kind.rawValue
                    }
                }
            }
        }
        // Table pipes.
        if text[range.lowerBound..<range.upperBound].contains(0x7C), text[range.lowerBound..<range.upperBound]
            .filter({ $0 == 0x7C }).count >= 2 {
            for position in range where text[position] == 0x7C && kinds[position] == 0 {
                kinds[position] = HighlightKind.operator.rawValue
            }
        }
    }

    private static let htmlComment = try! NSRegularExpression(pattern: #"<!--[\s\S]*?(?:-->|\z)"#)

    /// `<!-- … -->`, which may run over lines; ones that start inside a code block are code.
    private static func htmlComments(_ source: String, lines: [MarkdownStructure.Line], _ kinds: inout [UInt8]) {
        htmlComment.enumerateMatches(in: source, options: [], range: NSRange(location: 0, length: source.utf16.count)) {
            match, _, _ in
            guard let match else { return }

            let start = match.range.location
            let inCode = lines.contains { line in
                switch line.kind {
                case .code, .fenceOpen, .fenceClose: line.range.contains(start)
                default: false
                }
            }
            guard !inCode else { return }

            for position in start..<(start + match.range.length) { kinds[position] = HighlightKind.comment.rawValue }
        }
    }
}
