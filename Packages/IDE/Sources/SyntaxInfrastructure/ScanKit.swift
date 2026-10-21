import IDEDomain

/// What the line scanners share: a place to paint kinds, and the ends of lines.
struct Painter {
    var values: [UInt8]

    init(count: Int) { values = [UInt8](repeating: 0, count: count) }

    mutating func paint(_ range: Range<Int>, _ kind: HighlightKind) {
        guard range.lowerBound < range.upperBound else { return }

        for index in max(0, range.lowerBound)..<min(values.count, range.upperBound) { values[index] = kind.rawValue }
    }

    mutating func paint(_ index: Int, _ kind: HighlightKind) {
        if values.indices.contains(index) { values[index] = kind.rawValue }
    }
}

enum Scan {
    /// The lines of the text as UTF-16 ranges, terminators left out (`\n`, `\r\n`, `\r`).
    static func lines(in text: [UInt16]) -> [Range<Int>] {
        var result: [Range<Int>] = []
        var start = 0
        let count = text.count
        while start <= count {
            var end = start
            while end < count, text[end] != 0x0A, text[end] != 0x0D { end += 1 }

            result.append(start..<end)
            if end >= count { break }

            start = end + ((text[end] == 0x0D && end + 1 < count && text[end + 1] == 0x0A) ? 2 : 1)
        }

        return result
    }

    static func isSpace(_ unit: UInt16) -> Bool { unit == 0x20 || unit == 0x09 }

    static func isDigit(_ unit: UInt16) -> Bool { unit >= 0x30 && unit <= 0x39 }

    static func isWordStart(_ unit: UInt16) -> Bool {
        (unit >= 0x41 && unit <= 0x5A) || (unit >= 0x61 && unit <= 0x7A) || unit == 0x5F
    }

    static func isWordPart(_ unit: UInt16) -> Bool { isWordStart(unit) || isDigit(unit) }

    /// The index of the first unit from `start` (inside `range`) that is not a space or a tab.
    static func skipSpaces(_ text: [UInt16], from start: Int, to end: Int) -> Int {
        var index = start
        while index < end, isSpace(text[index]) { index += 1 }

        return index
    }

    /// The text of a range as a String, for comparing words.
    static func string(_ text: [UInt16], _ range: Range<Int>) -> String {
        String(decoding: text[range], as: UTF16.self)
    }

    /// The end of a quoted string that starts at `start` (a quote), within `end`: the index after the
    /// closing quote, or `end` if the line ends first. A backslash escapes the next unit if
    /// `escapes` is true.
    static func endOfQuoted(_ text: [UInt16], from start: Int, to end: Int, escapes: Bool = true) -> Int {
        let quote = text[start]
        var index = start + 1
        while index < end {
            if escapes, text[index] == 0x5C {
                index += 2
                continue
            }

            if text[index] == quote { return index + 1 }

            index += 1
        }

        return end
    }

    /// Paints `\x`, `\uXXXX` and the like inside a double-quoted string as escapes.
    static func paintEscapes(_ text: [UInt16], _ range: Range<Int>, _ painter: inout Painter) {
        var index = range.lowerBound
        while index < range.upperBound {
            if text[index] == 0x5C, index + 1 < range.upperBound {
                var end = index + 2
                if text[index + 1] == 0x75 { end = min(range.upperBound, index + 6) }

                painter.paint(index..<end, .escape)
                index = end
            } else {
                index += 1
            }
        }
    }

    /// Whether `word` is a number: `-12`, `3.5`, `1e9`, `0x1F`, `.5`.
    static func isNumber(_ word: String) -> Bool {
        guard !word.isEmpty else { return false }

        let body = word.hasPrefix("-") || word.hasPrefix("+") ? String(word.dropFirst()) : word
        guard !body.isEmpty else { return false }

        if body.hasPrefix("0x") || body.hasPrefix("0o") || body.hasPrefix("0b") { return body.count > 2 }

        return Double(body) != nil && body.first?.isNumber == true || body.hasPrefix(".") && Double("0" + body) != nil
    }
}
