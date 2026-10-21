import Foundation

extension DocumentFormatting {
    /// TOML with its white space made even: no indentation outside brackets, `key = value` with one
    /// space on each side of the equals sign, one blank line before a table, no trailing white space,
    /// no run of blank lines and a final line break. What the document says is checked to be the same
    /// afterwards; if it is not, the text is left alone.
    static func formatTOML(_ source: String) throws -> String {
        let original = Array(source.utf16)
        let before: TOMLValue
        do {
            before = try TOMLSyntax.parse(original)
        } catch let error as TOMLError {
            throw FormattingError("Fix the error first: \(error.message)")
        }

        var output: [String] = []
        var depth = 0
        var open: (quote: UInt16, literal: Bool)?

        for raw in splitLines(source) {
            // Inside a multi-line string the text is the document's own.
            if let inside = open {
                output.append(raw)
                if endsMultiline(raw, quote: inside.quote) { open = nil }

                continue
            }

            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                // Between brackets a blank line is the writer's; elsewhere there is at most one.
                if depth > 0 || (output.last.map { !$0.isEmpty } ?? false) { output.append("") }

                continue
            }

            let isHeader = depth == 0 && trimmed.hasPrefix("[")
            // A table is set apart by a blank line, unless a comment above it belongs to it.
            if isHeader, let last = output.last, !last.isEmpty, !last.hasPrefix("#") { output.append("") }

            var text = raw
            while let last = text.last, last == " " || last == "\t" { text.removeLast() }

            if depth == 0 { text = isHeader || trimmed.hasPrefix("#") ? trimmed : spaceEquals(trimmed) }

            let scan = scanLine(trimmed, depth: depth)
            output.append(text)
            depth = scan.depth
            open = scan.open
        }

        while output.last?.isEmpty == true { output.removeLast() }

        let result = output.joined(separator: "\n") + "\n"
        guard let after = try? TOMLSyntax.parse(Array(result.utf16)), after == before else {
            throw FormattingError("Formatting would change what the document says, so it was left alone")
        }

        return result
    }

    private static func splitLines(_ text: String) -> [String] {
        var lines: [String] = []
        var current = ""
        for character in text {
            if character == "\r\n" || character == "\n" || character == "\r" {
                lines.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { lines.append(current) }

        return lines
    }

    /// How the bracket depth stands at the end of the line, and whether a multi-line string is left open.
    private static func scanLine(_ line: String, depth start: Int) -> (depth: Int, open: (
        quote: UInt16,
        literal: Bool
    )?) {
        let units = Array(line.utf16)
        var depth = start
        var index = 0
        while index < units.count {
            let unit = units[index]
            if unit == 0x23 { break }

            if unit == 0x22 || unit == 0x27 {
                if index + 2 < units.count, units[index + 1] == unit, units[index + 2] == unit {
                    index += 3
                    guard let end = closingTriple(units, from: index, quote: unit) else {
                        return (depth, (unit, unit == 0x27))
                    }

                    index = end + 3
                } else {
                    index += 1
                    while index < units.count, units[index] != unit {
                        index += unit == 0x22 && units[index] == 0x5C ? 2 : 1
                    }

                    index += 1
                }

                continue
            }

            if unit == 0x5B || unit == 0x7B { depth += 1 }

            if unit == 0x5D || unit == 0x7D { depth = max(0, depth - 1) }

            index += 1
        }

        return (depth, nil)
    }

    /// Where a closing triple quote starts at or after `start`.
    private static func closingTriple(_ units: [UInt16], from start: Int, quote: UInt16) -> Int? {
        var index = start
        while index + 3 <= units.count {
            if quote == 0x22, units[index] == 0x5C {
                index += 2
                continue
            }

            if units[index] == quote, units[index + 1] == quote, units[index + 2] == quote { return index }

            index += 1
        }

        return nil
    }

    private static func endsMultiline(_ line: String, quote: UInt16) -> Bool {
        closingTriple(Array(line.utf16), from: 0, quote: quote) != nil
    }

    /// `key=value` and `key   =   value` as `key = value`, leaving what is inside quotes and after a `#`.
    private static func spaceEquals(_ line: String) -> String {
        let units = Array(line.utf16)
        var index = 0
        while index < units.count {
            let unit = units[index]
            if unit == 0x22 || unit == 0x27 {
                let quote = unit
                index += 1
                while index < units.count, units[index] != quote {
                    if quote == 0x22, units[index] == 0x5C { index += 1 }

                    index += 1
                }

                index += 1
                continue
            }

            if unit == 0x23 { return line }

            if unit == 0x3D {
                let key = String(decoding: units[0..<index], as: UTF16.self).trimmingCharacters(in: .whitespaces)
                let value = String(decoding: units[(index + 1)...], as: UTF16.self).trimmingCharacters(in: .whitespaces)

                return value.isEmpty ? key + " =" : key + " = " + value
            }

            index += 1
        }

        return line
    }
}
