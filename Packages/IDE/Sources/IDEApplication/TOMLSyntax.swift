import Foundation
import IDEDomain

/// What a TOML document says: its values, tables and arrays, without the way they were written.
public indirect enum TOMLValue: Equatable, Sendable {
    case string(String)
    case integer(String)
    case float(String)
    case boolean(Bool)
    case dateTime(String)
    case array([TOMLValue])
    case table([String: TOMLValue])
}

public struct TOMLError: Error, Equatable, Sendable {
    public let location: Int
    public let length: Int
    public let message: String
}

/// A reader of TOML 1.0 that follows the specification: it stops at the first mistake and says where,
/// and it knows what may not be said twice (a key, a table, or a table that a dotted key made).
public enum TOMLSyntax {
    /// The document's content, or the first mistake.
    public static func parse(_ text: [UInt16]) throws -> TOMLValue {
        var reader = Reader(text)
        try reader.document()

        return reader.root.value
    }

    public static func check(_ text: [UInt16]) -> [DocumentDiagnostic] {
        do {
            _ = try parse(text)

            return []
        } catch let error as TOMLError {
            return [DocumentDiagnostic(
                range: UTF16TextRange(location: error.location, length: error.length),
                severity: .error,
                message: error.message,
                source: "TOML"
            )]
        } catch {
            return []
        }
    }

    // MARK: Tables

    private final class Table {
        var entries: [String: Node] = [:]
        /// Opened by a `[header]` (or made by an `[[array]]` element).
        var byHeader = false
        /// Made by a dotted key such as `a.b = 1`.
        var byDottedKey = false
        var isInline = false

        var value: TOMLValue { .table(entries.mapValues(\.value)) }
    }

    private enum Node {
        case value(TOMLValue)
        case table(Table)
        case tables([Table])

        var value: TOMLValue {
            switch self {
            case .value(let value): value
            case .table(let table): table.value
            case .tables(let tables): .array(tables.map(\.value))
            }
        }
    }

    // MARK: The reader

    private struct Reader {
        let text: [UInt16]
        var index = 0
        let root = Table()
        var current: Table

        init(_ text: [UInt16]) {
            self.text = text
            current = root
        }

        mutating func document() throws {
            current = root
            while true {
                skipBlank()
                guard index < text.count else { return }

                if text[index] == 0x5B {
                    try header()
                } else {
                    try keyValue(into: current)
                }

                try endOfLine()
            }
        }

        // MARK: Characters

        func fail(_ message: String, at position: Int? = nil, length: Int = 1) -> TOMLError {
            let start = min(position ?? index, text.count)

            return TOMLError(
                location: start,
                length: start < text.count ? min(length, text.count - start) : 0,
                message: message
            )
        }

        var peek: UInt16? { index < text.count ? text[index] : nil }

        func isSpace(_ unit: UInt16) -> Bool { unit == 0x20 || unit == 0x09 }

        mutating func skipSpaces() {
            while let unit = peek, isSpace(unit) { index += 1 }
        }

        /// White space, comments and line breaks.
        mutating func skipBlank() {
            while let unit = peek {
                if isSpace(unit) || unit == 0x0A || unit == 0x0D {
                    index += 1
                } else if unit == 0x23 {
                    skipComment()
                } else {
                    return
                }
            }
        }

        mutating func skipComment() {
            while let unit = peek, unit != 0x0A, unit != 0x0D { index += 1 }
        }

        mutating func endOfLine() throws {
            skipSpaces()
            guard let unit = peek else { return }

            if unit == 0x23 {
                skipComment()

                return
            }

            guard unit == 0x0A || unit == 0x0D else { throw fail("Expected the end of the line after the value") }
        }

        // MARK: Keys

        mutating func key() throws -> String {
            skipSpaces()
            guard let unit = peek else { throw fail("Expected a key", length: 0) }

            if unit == 0x22 {
                return try basicString()
            }

            if unit == 0x27 {
                return try literalString()
            }

            let start = index
            while let next = peek, Scan.isWordPart(next) || next == 0x2D { index += 1 }

            guard index > start else { throw fail("Expected a key") }

            return String(decoding: text[start..<index], as: UTF16.self)
        }

        /// A key that may be dotted: its parts.
        mutating func dottedKey() throws -> [(name: String, location: Int)] {
            var parts: [(String, Int)] = []
            while true {
                skipSpaces()
                let start = index
                parts.append((try key(), start))
                skipSpaces()
                guard peek == 0x2E else { return parts }

                index += 1
            }
        }

        // MARK: Headers

        mutating func header() throws {
            let opening = index
            index += 1
            let isArray = peek == 0x5B
            if isArray { index += 1 }

            let parts = try dottedKey()
            skipSpaces()
            guard peek == 0x5D else { throw fail("Expected ']' to close the table name") }

            index += 1
            if isArray {
                guard peek == 0x5D else { throw fail("Expected ']]' to close the table name") }

                index += 1
            }

            var table = root
            let name = parts.map(\.name).joined(separator: ".")
            for (position, part) in parts.enumerated() {
                let isLast = position == parts.count - 1
                switch table.entries[part.name] {
                case nil:
                    let made = Table()
                    if isLast, isArray {
                        made.byHeader = true
                        table.entries[part.name] = .tables([made])
                    } else {
                        made.byHeader = isLast
                        table.entries[part.name] = .table(made)
                    }

                    table = made
                case .table(let existing):
                    if isLast {
                        if isArray {
                            throw fail("\(name) is already a table, not an array of tables", at: opening, length: 2)
                        }

                        guard !existing.byHeader, !existing.byDottedKey, !existing.isInline else {
                            throw fail("The table [\(name)] is defined twice", at: opening)
                        }

                        existing.byHeader = true
                    }

                    table = existing
                case .tables(let list):
                    if isLast {
                        guard isArray else { throw fail("\(name) is an array of tables; use [[\(name)]]", at: opening) }

                        let made = Table()
                        made.byHeader = true
                        table.entries[part.name] = .tables(list + [made])
                        table = made
                    } else {
                        table = list[list.count - 1]
                    }
                case .value:
                    throw fail(
                        "\(part.name) is already defined as a value, not a table",
                        at: part.location,
                        length: part.name.utf16.count
                    )
                }
            }
            current = table
        }

        // MARK: Key and value

        mutating func keyValue(into table: Table) throws {
            let parts = try dottedKey()
            skipSpaces()
            guard peek == 0x3D else { throw fail("Expected '=' after the key") }

            index += 1
            skipSpaces()
            var target = table
            for part in parts.dropLast() {
                switch target.entries[part.name] {
                case nil:
                    let made = Table()
                    made.byDottedKey = true
                    target.entries[part.name] = .table(made)
                    target = made
                case .table(let existing):
                    guard !existing.isInline, !existing.byHeader || existing === table else {
                        throw fail(
                            "The table \(part.name) cannot be extended here",
                            at: part.location,
                            length: part.name.utf16.count
                        )
                    }

                    target = existing
                default:
                    throw fail(
                        "\(part.name) is already defined as a value",
                        at: part.location,
                        length: part.name.utf16.count
                    )
                }
            }
            guard let last = parts.last else { return }

            guard target.entries[last.name] == nil else {
                throw fail("The key \(last.name) is defined twice", at: last.location, length: last.name.utf16.count)
            }

            target.entries[last.name] = try valueNode()
        }

        mutating func valueNode() throws -> Node {
            guard let unit = peek else { throw fail("Expected a value", length: 0) }

            if unit == 0x7B {
                let table = Table()
                table.isInline = true
                try inlineTable(table)

                return .table(table)
            }

            return .value(try value())
        }

        mutating func value() throws -> TOMLValue {
            guard let unit = peek else { throw fail("Expected a value", length: 0) }

            switch unit {
            case 0x22:
                if index + 2 < text.count, text[index + 1] == 0x22, text[index + 2] == 0x22 {
                    return .string(try multilineBasic())
                }

                return .string(try basicString())
            case 0x27:
                if index + 2 < text.count, text[index + 1] == 0x27, text[index + 2] == 0x27 {
                    return .string(try multilineLiteral())
                }

                return .string(try literalString())
            case 0x5B: return try array()
            case 0x7B:
                let table = Table()
                table.isInline = true
                try inlineTable(table)

                return table.value
            default: return try bareValue()
            }
        }

        // MARK: Strings

        mutating func basicString() throws -> String {
            let start = index
            index += 1
            var result: [UInt16] = []
            while let unit = peek {
                if unit == 0x22 {
                    index += 1

                    return String(decoding: result, as: UTF16.self)
                }

                if unit == 0x0A || unit == 0x0D { break }

                if unit == 0x5C {
                    result.append(contentsOf: try escape())
                } else if unit < 0x20 && unit != 0x09 {
                    throw fail("A control character in a string must be written as an escape")
                } else {
                    result.append(unit)
                    index += 1
                }
            }

            throw fail("This string is never closed", at: start)
        }

        mutating func escape() throws -> [UInt16] {
            let start = index
            index += 1
            guard let unit = peek else { throw fail("Unfinished escape", at: start, length: 1) }

            index += 1
            switch unit {
            case 0x62: return [0x08]
            case 0x74: return [0x09]
            case 0x6E: return [0x0A]
            case 0x66: return [0x0C]
            case 0x72: return [0x0D]
            case 0x22: return [0x22]
            case 0x5C: return [0x5C]
            case 0x75, 0x55:
                let digits = unit == 0x75 ? 4 : 8
                guard index + digits <= text.count,
                      let scalar = UInt32(String(decoding: text[index..<(index + digits)], as: UTF16.self), radix: 16),
                      let value = Unicode.Scalar(scalar) else {
                    throw fail(
                        "A \\\(unit == 0x75 ? "u" : "U") escape needs \(digits) hexadecimal digits "
                            + "for a valid character",
                        at: start,
                        length: 2
                    )
                }

                index += digits

                return Array(String(Character(value)).utf16)
            default:
                throw fail("Unknown escape in a string", at: start, length: 2)
            }
        }

        mutating func literalString() throws -> String {
            let start = index
            index += 1
            let begin = index
            while let unit = peek {
                if unit == 0x27 {
                    index += 1

                    return String(decoding: text[begin..<(index - 1)], as: UTF16.self)
                }

                if unit == 0x0A || unit == 0x0D { break }

                index += 1
            }

            throw fail("This string is never closed", at: start)
        }

        mutating func multilineBasic() throws -> String {
            let start = index
            index += 3
            if peek == 0x0D, index + 1 < text.count, text[index + 1] == 0x0A { index += 2 } else if peek == 0x0A {
                index += 1
            }

            var result: [UInt16] = []
            while index < text.count {
                if hasQuotes(at: index, count: 3) {
                    // Up to two more quotes may belong to the string.
                    var end = index + 3
                    while end < text.count, text[end] == 0x22, end - index < 5 { end += 1 }

                    result.append(contentsOf: [UInt16](repeating: 0x22, count: end - index - 3))
                    index = end

                    return String(decoding: result, as: UTF16.self)
                }

                if text[index] == 0x5C {
                    // A backslash at the end of a line takes the line break and the white space after it.
                    var look = index + 1
                    while look < text.count, isSpace(text[look]) { look += 1 }

                    if look < text.count, text[look] == 0x0A || text[look] == 0x0D {
                        while look < text.count, isSpace(text[look]) || text[look] == 0x0A || text[look] == 0x0D {
                            look += 1
                        }

                        index = look
                        continue
                    }

                    result.append(contentsOf: try escape())
                } else {
                    result.append(text[index])
                    index += 1
                }
            }

            throw fail("This string is never closed", at: start, length: 3)
        }

        func hasQuotes(at position: Int, count: Int) -> Bool {
            position + count <= text.count && (0..<count).allSatisfy { text[position + $0] == 0x22 }
        }

        mutating func multilineLiteral() throws -> String {
            let start = index
            index += 3
            if peek == 0x0D, index + 1 < text.count, text[index + 1] == 0x0A { index += 2 } else if peek == 0x0A {
                index += 1
            }

            let begin = index
            while index + 3 <= text.count {
                if text[index] == 0x27, text[index + 1] == 0x27, text[index + 2] == 0x27 {
                    var end = index + 3
                    while end < text.count, text[end] == 0x27, end - index < 5 { end += 1 }

                    let content = String(decoding: text[begin..<(end - 3)], as: UTF16.self)
                    index = end

                    return content
                }

                index += 1
            }

            throw fail("This string is never closed", at: start, length: 3)
        }

        // MARK: Arrays and inline tables

        mutating func array() throws -> TOMLValue {
            let start = index
            index += 1
            var items: [TOMLValue] = []
            while true {
                skipBlank()
                guard let unit = peek else { throw fail("This array is never closed", at: start) }

                if unit == 0x5D {
                    index += 1

                    return .array(items)
                }

                items.append(try value())
                skipBlank()
                guard let next = peek else { throw fail("This array is never closed", at: start) }

                if next == 0x2C { index += 1 } else if next == 0x5D {
                    index += 1

                    return .array(items)
                } else {
                    throw fail("Expected ',' or ']' in the array")
                }
            }
        }

        mutating func inlineTable(_ table: Table) throws {
            let start = index
            index += 1
            skipSpaces()
            if peek == 0x7D {
                index += 1

                return
            }

            while true {
                skipSpaces()
                guard peek != nil, peek != 0x0A, peek != 0x0D else {
                    throw fail("This inline table is never closed", at: start)
                }

                try keyValue(into: table)
                skipSpaces()
                guard let unit = peek else { throw fail("This inline table is never closed", at: start) }

                if unit == 0x2C {
                    index += 1
                    skipSpaces()
                    if peek == 0x7D {
                        throw fail("A comma cannot come before the closing '}' of an inline table", at: index - 1)
                    }
                } else if unit == 0x7D {
                    index += 1

                    return
                } else {
                    throw fail("Expected ',' or '}' in the inline table")
                }
            }
        }

        // MARK: Numbers, booleans, dates

        mutating func bareValue() throws -> TOMLValue {
            let start = index
            while let unit = peek, !isSpace(unit), ![0x2C, 0x5D, 0x7D, 0x23, 0x0A, 0x0D].contains(unit) { index += 1 }

            var word = String(decoding: text[start..<index], as: UTF16.self)
            // A date and a time may be written with a space between them.
            if index + 1 < text.count, isSpace(text[index]), looksLikeDate(word), isDigit(text[index + 1]) {
                let before = index
                skipSpaces()
                let timeStart = index
                while let unit = peek, !isSpace(unit), ![0x2C, 0x5D, 0x7D, 0x23, 0x0A, 0x0D].contains(unit) {
                    index += 1
                }

                let time = String(decoding: text[timeStart..<index], as: UTF16.self)
                if looksLikeTime(time) { word += " " + time } else { index = before }
            }

            guard !word.isEmpty else { throw fail("Expected a value") }

            if word == "true" { return .boolean(true) }

            if word == "false" { return .boolean(false) }

            if looksLikeDate(word) || looksLikeTime(word) { return .dateTime(word) }

            if Self.integer.firstMatch(in: word) { return .integer(word) }

            if Self.float.firstMatch(in: word) { return .float(word) }

            throw fail("This is not a valid TOML value", at: start, length: max(1, index - start))
        }

        func isDigit(_ unit: UInt16) -> Bool { unit >= 0x30 && unit <= 0x39 }

        func looksLikeDate(_ word: String) -> Bool { Self.date.firstMatch(in: word) }

        func looksLikeTime(_ word: String) -> Bool { Self.time.firstMatch(in: word) }

        static let integer =
            Pattern(#"^([+-]?(0|[1-9](_?[0-9])*)|0x[0-9A-Fa-f](_?[0-9A-Fa-f])*|0o[0-7](_?[0-7])*|0b[01](_?[01])*)$"#)
        static let float =
            Pattern(#"^([+-]?(0|[1-9](_?[0-9])*)(\.[0-9](_?[0-9])*)?([eE][+-]?[0-9](_?[0-9])*)?|[+-]?(inf|nan))$"#)
        static let date = Pattern(
            #"^[0-9]{4}-[0-9]{2}-[0-9]{2}([Tt ][0-9]{2}:[0-9]{2}(:[0-9]{2}(\.[0-9]+)?)?"#
                + #"([Zz]|[+-][0-9]{2}:[0-9]{2})?)?$"#
        )
        static let time = Pattern(#"^[0-9]{2}:[0-9]{2}(:[0-9]{2}(\.[0-9]+)?)?([Zz]|[+-][0-9]{2}:[0-9]{2})?$"#)
    }

    private struct Pattern {
        let expression: NSRegularExpression

        init(_ pattern: String) { expression = try! NSRegularExpression(pattern: pattern) }

        func firstMatch(in word: String) -> Bool {
            expression.firstMatch(in: word, range: NSRange(location: 0, length: (word as NSString).length)) != nil
        }
    }
}
