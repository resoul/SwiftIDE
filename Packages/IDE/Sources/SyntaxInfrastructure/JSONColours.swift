import IDEDomain

/// Colours JSON (and JSON with comments): keys, string values, numbers, `true`/`false`/`null`.
enum JSONColours {
    static func kinds(for text: [UInt16]) -> [UInt8] {
        var painter = Painter(count: text.count)
        var index = 0
        let count = text.count
        while index < count {
            let unit = text[index]
            switch unit {
            case 0x22:
                let end = endOfString(text, from: index)
                var next = end
                while next < count, Scan.isSpace(text[next]) || text[next] == 0x0A || text[next] == 0x0D { next += 1 }

                let isKey = next < count && text[next] == 0x3A
                painter.paint(index..<end, isKey ? .property : .string)
                Scan.paintEscapes(text, (index + 1)..<max(index + 1, end - 1), &painter)
                index = end
            case 0x2F where index + 1 < count && text[index + 1] == 0x2F:
                var end = index
                while end < count, text[end] != 0x0A, text[end] != 0x0D { end += 1 }

                painter.paint(index..<end, .comment)
                index = end
            case 0x2F where index + 1 < count && text[index + 1] == 0x2A:
                var end = index + 2
                while end + 1 < count, !(text[end] == 0x2A && text[end + 1] == 0x2F) { end += 1 }

                end = min(count, end + 2)
                painter.paint(index..<end, .comment)
                index = end
            case 0x2D, 0x30...0x39:
                var end = index + 1
                while end < count, Scan.isDigit(text[end]) || [0x2E, 0x65, 0x45, 0x2B, 0x2D].contains(text[end]) {
                    end += 1
                }

                painter.paint(index..<end, .number)
                index = end
            default:
                if Scan.isWordStart(unit) {
                    var end = index + 1
                    while end < count, Scan.isWordPart(text[end]) { end += 1 }

                    if ["true", "false", "null"].contains(Scan.string(text, index..<end)) {
                        painter.paint(index..<end, .constant)
                    }

                    index = end
                } else {
                    index += 1
                }
            }
        }

        return painter.values
    }

    /// The index after the closing quote of the string that starts at `start`; a string stops at a
    /// line end (an unterminated string), so that one missing quote does not colour the rest.
    private static func endOfString(_ text: [UInt16], from start: Int) -> Int {
        var index = start + 1
        while index < text.count {
            if text[index] == 0x5C {
                index += 2
                continue
            }

            if text[index] == 0x22 { return index + 1 }

            if text[index] == 0x0A || text[index] == 0x0D { return index }

            index += 1
        }

        return min(index, text.count)
    }
}
