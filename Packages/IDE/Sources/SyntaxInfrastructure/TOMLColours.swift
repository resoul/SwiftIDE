import IDEDomain

/// Colours TOML: comments, `[table]` and `[[array of tables]]` headers, keys, strings (also the
/// triple-quoted ones that run over lines), numbers, dates and booleans.
enum TOMLColours {
    static func kinds(for text: [UInt16]) -> [UInt8] {
        var painter = Painter(count: text.count)
        var openString: (quote: UInt16, literal: Bool)?

        for line in Scan.lines(in: text) {
            var index = line.lowerBound
            // The rest of a multi-line string.
            if let open = openString {
                let stop = endOfMultiline(text, from: index, to: line.upperBound, open: open)
                painter.paint(index..<stop.end, .string)
                if !open.literal { Scan.paintEscapes(text, index..<stop.end, &painter) }

                if stop.closed { openString = nil } else { continue }

                index = stop.end
            }

            index = Scan.skipSpaces(text, from: index, to: line.upperBound)
            guard index < line.upperBound else { continue }

            if text[index] == 0x23 {
                painter.paint(index..<line.upperBound, .comment)
                continue
            }

            if text[index] == 0x5B, openString == nil {
                // A table header, with a comment after it perhaps.
                var stop = index
                while stop < line.upperBound, text[stop] != 0x23 { stop += 1 }

                var headerEnd = stop
                while headerEnd > index, Scan.isSpace(text[headerEnd - 1]) { headerEnd -= 1 }

                painter.paint(index..<headerEnd, .type)
                if stop < line.upperBound { painter.paint(stop..<line.upperBound, .comment) }

                continue
            }

            // A key, an equals sign, a value.
            var cursor = index
            var sawEquals = false
            while cursor < line.upperBound {
                let unit = text[cursor]
                if !sawEquals {
                    if unit == 0x3D {
                        sawEquals = true
                        painter.paint(cursor, .operator)
                        cursor += 1
                    } else if unit == 0x22 || unit == 0x27 {
                        let end = Scan.endOfQuoted(text, from: cursor, to: line.upperBound, escapes: unit == 0x22)
                        painter.paint(cursor..<end, .property)
                        cursor = end
                    } else if Scan.isSpace(unit) || unit == 0x2E {
                        cursor += 1
                    } else {
                        let start = cursor
                        while cursor < line.upperBound, Scan.isWordPart(text[cursor]) || text[cursor] == 0x2D {
                            cursor += 1
                        }

                        painter.paint(start..<max(cursor, start + 1), .property)
                        cursor = max(cursor, start + 1)
                    }

                    continue
                }

                if unit == 0x23 {
                    painter.paint(cursor..<line.upperBound, .comment)
                    break
                }

                if unit == 0x22 || unit == 0x27 {
                    let triple = cursor + 2 < line.upperBound && text[cursor + 1] == unit && text[cursor + 2] == unit
                    if triple {
                        let open = (quote: unit, literal: unit == 0x27)
                        let stop = endOfMultiline(text, from: cursor + 3, to: line.upperBound, open: open)
                        painter.paint(cursor..<stop.end, .string)
                        if !open.literal { Scan.paintEscapes(text, (cursor + 3)..<stop.end, &painter) }

                        if !stop.closed { openString = open }

                        cursor = stop.end
                    } else {
                        let end = Scan.endOfQuoted(text, from: cursor, to: line.upperBound, escapes: unit == 0x22)
                        painter.paint(cursor..<end, .string)
                        if unit == 0x22 { Scan.paintEscapes(text, (cursor + 1)..<max(cursor + 1, end - 1), &painter) }

                        cursor = end
                    }

                    continue
                }

                if [0x5B, 0x5D, 0x7B, 0x7D, 0x2C].contains(unit) {
                    painter.paint(cursor, .operator)
                    cursor += 1
                } else if Scan.isSpace(unit) || unit == 0x3D {
                    cursor += 1
                } else {
                    var end = cursor
                    while end < line.upperBound, ![0x2C, 0x5D, 0x7D, 0x23, 0x20, 0x09].contains(text[end]) { end += 1 }

                    let word = Scan.string(text, cursor..<end)
                    if ["true", "false"].contains(word) {
                        painter.paint(cursor..<end, .constant)
                    } else if Scan.isNumber(word.replacingOccurrences(of: "_", with: "")) || isDate(word)
                        || ["inf", "-inf", "+inf", "nan"].contains(word) {
                        painter.paint(cursor..<end, .number)
                    }

                    cursor = max(end, cursor + 1)
                }
            }
        }

        return painter.values
    }

    private static func isDate(_ word: String) -> Bool {
        let units = Array(word.utf8)
        guard units.count >= 8 else { return false }

        // 1979-05-27, 07:32:00, and the two joined.
        let date = units.count >= 10 && units[4] == 0x2D && units[7] == 0x2D && units.prefix(4).allSatisfy {
            $0 >= 0x30 && $0 <= 0x39
        }
        let time = units[2] == 0x3A && units[5] == 0x3A

        return date || time
    }

    /// Where a multi-line string that is open at `start` ends on this line.
    private static func endOfMultiline(
        _ text: [UInt16],
        from start: Int,
        to end: Int,
        open: (quote: UInt16, literal: Bool)
    ) -> (end: Int, closed: Bool) {
        var index = start
        while index < end {
            if !open.literal, text[index] == 0x5C {
                index += 2
                continue
            }

            if index + 3 <= end, text[index] == open.quote, text[index + 1] == open.quote,
               text[index + 2] == open.quote {
                return (index + 3, true)
            }

            index += 1
        }

        return (end, false)
    }
}
