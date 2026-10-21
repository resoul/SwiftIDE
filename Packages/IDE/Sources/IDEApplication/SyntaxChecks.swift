import Foundation
import IDEDomain

/// Finds syntax errors in the languages that can be checked without a server: JSON and XML (which
/// includes property lists). The answer is a list of problems placed in the text, as a language
/// server's would be.
public enum SyntaxChecks {
    public static func supports(_ language: DocumentLanguage) -> Bool {
        language == .json || language == .xml || language == .toml
    }

    /// The problems in `text`, at most one error per kind of file (the first). A text with nothing
    /// but white space has none.
    public static func check(
        _ text: [UInt16],
        language: DocumentLanguage,
        fileName: String = ""
    ) -> [DocumentDiagnostic] {
        guard !text.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0D }) else { return [] }

        switch language {
        case .json: return JSONSyntax(text).check()
        case .xml: return XMLSyntax.check(text, fileName: fileName)
        case .toml: return TOMLSyntax.check(text)
        default: return []
        }
    }
}

// MARK: JSON

/// A strict JSON reader that stops at the first error and says where. Comments are allowed, as a
/// warning, because many files named .json (editor settings, tsconfig) have them and only some
/// readers accept them.
struct JSONSyntax {
    private let text: [UInt16]
    private var index = 0
    private var problems: [DocumentDiagnostic] = []
    private var failed = false
    private static let maximumDepth = 512

    init(_ text: [UInt16]) { self.text = text }

    func check() -> [DocumentDiagnostic] {
        var reader = self
        reader.run()

        return reader.problems
    }

    private mutating func run() {
        skipSpace()
        guard !failed else { return }

        value(depth: 0)
        guard !failed else { return }

        skipSpace()
        if !failed, index < text.count { fail("Unexpected content after the end of the document", length: 1) }
    }

    private mutating func fail(_ message: String, at position: Int? = nil, length: Int = 1) {
        guard !failed else { return }

        failed = true
        let start = min(position ?? index, text.count)
        problems.append(DocumentDiagnostic(
            range: UTF16TextRange(location: start, length: start < text.count ? min(length, text.count - start) : 0),
            severity: .error,
            message: message,
            source: "JSON"
        ))
    }

    private func peek() -> UInt16? { index < text.count ? text[index] : nil }

    /// Skips white space and comments; a comment is a warning.
    private mutating func skipSpace() {
        while index < text.count {
            let unit = text[index]
            if unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D {
                index += 1
            } else if unit == 0x2F, index + 1 < text.count, text[index + 1] == 0x2F || text[index + 1] == 0x2A {
                let start = index
                if text[index + 1] == 0x2F {
                    while index < text.count, text[index] != 0x0A, text[index] != 0x0D { index += 1 }
                } else {
                    index += 2
                    while index + 1 < text.count, !(text[index] == 0x2A && text[index + 1] == 0x2F) { index += 1 }

                    guard index + 1 < text.count else {
                        fail("Unterminated comment", at: start, length: 2)

                        return
                    }

                    index += 2
                }

                if !problems.contains(where: { $0.severity == .warning }) {
                    problems.append(DocumentDiagnostic(
                        range: UTF16TextRange(location: start, length: min(2, text.count - start)),
                        severity: .warning,
                        message: "Comments are not allowed in JSON",
                        source: "JSON"
                    ))
                }
            } else {
                return
            }
        }
    }

    private mutating func value(depth: Int) {
        guard depth <= Self.maximumDepth else { return fail("Nested too deeply") }

        guard let unit = peek() else { return fail("Unexpected end of the document", length: 0) }

        switch unit {
        case 0x7B: object(depth: depth)
        case 0x5B: array(depth: depth)
        case 0x22: string()
        case 0x2D, 0x30...0x39: number()
        default:
            for literal in ["true", "false", "null"] where matches(literal) {
                index += literal.utf16.count
                if let next = peek(), Scan.isWordPart(next) { fail("Unexpected character", length: 1) }

                return
            }

            fail("Unexpected character; expected a value")
        }
    }

    private func matches(_ literal: String) -> Bool {
        let units = Array(literal.utf16)
        guard index + units.count <= text.count else { return false }

        return Array(text[index..<(index + units.count)]) == units
    }

    private mutating func object(depth: Int) {
        index += 1
        skipSpace()
        if failed { return }

        if peek() == 0x7D {
            index += 1

            return
        }

        while !failed {
            guard peek() == 0x22 else {
                return fail(
                    peek() == nil ? "Unexpected end of the document" : "Expected a string as the key",
                    length: peek() == nil ? 0 : 1
                )
            }

            string()
            skipSpace()
            guard !failed else { return }

            guard peek() == 0x3A else { return fail("Expected ':' after the key", length: peek() == nil ? 0 : 1) }

            index += 1
            skipSpace()
            value(depth: depth + 1)
            skipSpace()
            guard !failed else { return }

            switch peek() {
            case 0x2C:
                let comma = index
                index += 1
                skipSpace()
                if peek() == 0x7D { return fail("A comma cannot come before the closing '}'", at: comma) }
            case 0x7D:
                index += 1

                return
            default:
                return fail("Expected ',' or '}'", length: peek() == nil ? 0 : 1)
            }
        }
    }

    private mutating func array(depth: Int) {
        index += 1
        skipSpace()
        if failed { return }

        if peek() == 0x5D {
            index += 1

            return
        }

        while !failed {
            value(depth: depth + 1)
            skipSpace()
            guard !failed else { return }

            switch peek() {
            case 0x2C:
                let comma = index
                index += 1
                skipSpace()
                if peek() == 0x5D { return fail("A comma cannot come before the closing ']'", at: comma) }
            case 0x5D:
                index += 1

                return
            default:
                return fail("Expected ',' or ']'", length: peek() == nil ? 0 : 1)
            }
        }
    }

    private mutating func string() {
        let start = index
        index += 1
        while index < text.count {
            let unit = text[index]
            if unit == 0x22 {
                index += 1

                return
            }

            if unit < 0x20 {
                return fail("A line break or control character in a string must be written as an escape", length: 1)
            }

            if unit == 0x5C {
                guard index + 1 < text.count else { break }

                let next = text[index + 1]
                if next == 0x75 {
                    let digits = text[min(text.count, index + 2)..<min(text.count, index + 6)]
                    guard digits.count == 4, digits.allSatisfy(Self.isHex) else {
                        return fail("\\u must be followed by four hexadecimal digits", at: index, length: 2)
                    }

                    index += 6
                } else if [0x22, 0x5C, 0x2F, 0x62, 0x66, 0x6E, 0x72, 0x74].contains(next) {
                    index += 2
                } else {
                    return fail("Unknown escape in a string", at: index, length: 2)
                }
            } else {
                index += 1
            }
        }
        fail("Unterminated string", at: start, length: 1)
    }

    private static func isHex(_ unit: UInt16) -> Bool {
        (unit >= 0x30 && unit <= 0x39) || (unit >= 0x41 && unit <= 0x46) || (unit >= 0x61 && unit <= 0x66)
    }

    private mutating func number() {
        let start = index
        if peek() == 0x2D { index += 1 }

        guard let first = peek(), Scan.isDigit(first) else { return fail("Invalid number", at: start, length: 1) }

        if first == 0x30 {
            index += 1
            if let next = peek(), Scan.isDigit(next) {
                return fail("A number cannot start with a leading zero", at: start)
            }
        } else {
            while let next = peek(), Scan.isDigit(next) { index += 1 }
        }

        if peek() == 0x2E {
            index += 1
            guard let digit = peek(), Scan.isDigit(digit) else {
                return fail("Digits must follow the decimal point", at: start)
            }

            while let next = peek(), Scan.isDigit(next) { index += 1 }
        }

        if peek() == 0x65 || peek() == 0x45 {
            index += 1
            if peek() == 0x2B || peek() == 0x2D { index += 1 }

            guard let digit = peek(), Scan.isDigit(digit) else {
                return fail("Digits must follow the exponent", at: start)
            }

            while let next = peek(), Scan.isDigit(next) { index += 1 }
        }

        if let next = peek(), Scan.isWordPart(next) { fail("Invalid number", at: start, length: index - start + 1) }
    }
}

/// Small helpers the checks share with the scanners.
enum Scan {
    static func isDigit(_ unit: UInt16) -> Bool { unit >= 0x30 && unit <= 0x39 }

    static func isWordPart(_ unit: UInt16) -> Bool {
        (unit >= 0x41 && unit <= 0x5A) || (unit >= 0x61 && unit <= 0x7A) || unit == 0x5F || isDigit(unit)
    }
}

// MARK: XML

enum XMLSyntax {
    static func check(_ text: [UInt16], fileName: String) -> [DocumentDiagnostic] {
        // The scan below says what is wrong, in words; the parser is the second opinion.
        if let own = Reader(text).firstProblem() {
            return [DocumentDiagnostic(
                range: UTF16TextRange(
                    location: own.location,
                    length: min(own.length, max(0, text.count - own.location))
                ),
                severity: .error,
                message: own.message,
                source: "XML"
            )]
        }

        let string = String(decoding: text, as: UTF16.self)
        guard let data = string.data(using: .utf8) else { return [] }

        let parser = XMLParser(data: data)
        let delegate = Collector()
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        if parser.parse() {
            return propertyListProblems(data, root: delegate.root, text: text, fileName: fileName)
        }

        guard parser.parserError != nil else { return [] }

        let location = offset(ofLine: max(1, parser.lineNumber), column: max(1, parser.columnNumber), in: text)

        return [DocumentDiagnostic(
            range: UTF16TextRange(location: location, length: location < text.count ? 1 : 0),
            severity: .error,
            message: "The text is not well-formed XML",
            source: "XML"
        )]
    }

    /// A reading of tags, attributes, comments and entities that finds the usual mistakes and says what they are.
    private struct Reader {
        struct Problem {
            let location: Int
            let length: Int
            let message: String
        }

        let text: [UInt16]

        init(_ text: [UInt16]) { self.text = text }

        func firstProblem() -> Problem? {
            var index = 0
            let count = text.count
            var stack: [(name: String, location: Int)] = []

            func starts(_ literal: String, at position: Int) -> Bool {
                let units = Array(literal.utf16)
                guard position + units.count <= count else { return false }

                return Array(text[position..<(position + units.count)]) == units
            }

            func find(_ literal: String, from position: Int) -> Int? {
                var scan = position
                while scan < count {
                    if starts(literal, at: scan) { return scan }

                    scan += 1
                }

                return nil
            }

            func isNameStart(_ unit: UInt16) -> Bool {
                Scan.isWordPart(unit) && !Scan.isDigit(unit) || unit == 0x3A || unit > 0x7F
            }

            func isNamePart(_ unit: UInt16) -> Bool {
                isNameStart(unit) || Scan.isDigit(unit) || unit == 0x2D || unit == 0x2E
            }

            func readName(_ position: Int) -> Int {
                var end = position
                while end < count, isNamePart(text[end]) { end += 1 }

                return end
            }

            func isSpace(_ unit: UInt16) -> Bool { unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D }

            while index < count {
                let unit = text[index]
                if unit == 0x26 {
                    // An entity: a name or a number between & and ;.
                    var end = index + 1
                    if end < count, text[end] == 0x23 {
                        end += 1
                        if end < count, text[end] == 0x78 { end += 1 }

                        while end < count, Scan.isDigit(text[end]) || (text[end] >= 0x41 && text[end] <= 0x46)
                            || (text[end] >= 0x61 && text[end] <= 0x66) { end += 1 }
                    } else {
                        end = readName(end)
                    }

                    guard end > index + 1, end < count, text[end] == 0x3B else {
                        return Problem(
                            location: index,
                            length: 1,
                            message: "An '&' must be written as &amp; or start an entity such as &lt;"
                        )
                    }

                    index = end + 1
                } else if unit == 0x3C {
                    if starts("<!--", at: index) {
                        guard let end = find("-->", from: index + 4) else {
                            return Problem(location: index, length: 4, message: "This comment is never closed")
                        }

                        index = end + 3
                    } else if starts("<![CDATA[", at: index) {
                        guard let end = find("]]>", from: index + 9) else {
                            return Problem(location: index, length: 9, message: "This CDATA section is never closed")
                        }

                        index = end + 3
                    } else if starts("<?", at: index) {
                        guard let end = find("?>", from: index + 2) else {
                            return Problem(location: index, length: 2, message: "This declaration is never closed")
                        }

                        index = end + 2
                    } else if starts("<!", at: index) {
                        guard let end = find(">", from: index + 2) else {
                            return Problem(location: index, length: 2, message: "This declaration is never closed")
                        }

                        index = end + 1
                    } else if index + 1 < count, text[index + 1] == 0x2F {
                        let nameStart = index + 2
                        let nameEnd = readName(nameStart)
                        let name = String(decoding: text[nameStart..<nameEnd], as: UTF16.self)
                        var close = nameEnd
                        while close < count, isSpace(text[close]) { close += 1 }

                        guard nameEnd > nameStart, close < count, text[close] == 0x3E else {
                            return Problem(
                                location: index,
                                length: 2,
                                message: "A closing tag is not written as </name>"
                            )
                        }

                        guard let open = stack.last else {
                            return Problem(
                                location: nameStart,
                                length: max(1, nameEnd - nameStart),
                                message: "There is no open tag for </\(name)>"
                            )
                        }

                        guard open.name == name else {
                            return Problem(
                                location: nameStart,
                                length: max(1, nameEnd - nameStart),
                                message: "The closing tag </\(name)> does not match <\(open.name)>"
                            )
                        }

                        stack.removeLast()
                        index = close + 1
                    } else {
                        guard index + 1 < count, isNameStart(text[index + 1]) else {
                            return Problem(
                                location: index,
                                length: 1,
                                message: "A '<' must start a tag, or be written as &lt;"
                            )
                        }

                        let nameStart = index + 1
                        var cursor = readName(nameStart)
                        let name = String(decoding: text[nameStart..<cursor], as: UTF16.self)
                        var attributes: Set<String> = []
                        var selfClosing = false
                        while true {
                            while cursor < count, isSpace(text[cursor]) { cursor += 1 }

                            guard cursor < count else {
                                return Problem(
                                    location: index,
                                    length: max(1, nameStart - index + name.utf16.count),
                                    message: "The tag <\(name)> is never finished with '>'"
                                )
                            }

                            if text[cursor] == 0x3E {
                                cursor += 1
                                break
                            }

                            if text[cursor] == 0x2F, cursor + 1 < count, text[cursor + 1] == 0x3E {
                                selfClosing = true
                                cursor += 2
                                break
                            }

                            guard isNameStart(text[cursor]) else {
                                return Problem(
                                    location: cursor,
                                    length: 1,
                                    message: "An attribute name was expected here"
                                )
                            }

                            let attributeEnd = readName(cursor)
                            let attribute = String(decoding: text[cursor..<attributeEnd], as: UTF16.self)
                            guard attributes.insert(attribute).inserted else {
                                return Problem(
                                    location: cursor,
                                    length: attributeEnd - cursor,
                                    message: "The attribute \(attribute) is given twice"
                                )
                            }

                            var after = attributeEnd
                            while after < count, isSpace(text[after]) { after += 1 }

                            guard after < count, text[after] == 0x3D else {
                                return Problem(
                                    location: cursor,
                                    length: attributeEnd - cursor,
                                    message: "The attribute \(attribute) has no value; write \(attribute)=\"…\""
                                )
                            }

                            after += 1
                            while after < count, isSpace(text[after]) { after += 1 }

                            guard after < count, text[after] == 0x22 || text[after] == 0x27 else {
                                return Problem(
                                    location: min(after, count - 1),
                                    length: 1,
                                    message: "The value of \(attribute) must be in quotes"
                                )
                            }

                            let quote = text[after]
                            var valueEnd = after + 1
                            while valueEnd < count, text[valueEnd] != quote { valueEnd += 1 }

                            guard valueEnd < count else {
                                return Problem(
                                    location: after,
                                    length: 1,
                                    message: "This attribute value is never closed"
                                )
                            }

                            cursor = valueEnd + 1
                        }
                        if !selfClosing { stack.append((name, index)) }

                        index = cursor
                    }
                } else {
                    index += 1
                }
            }

            if let open = stack.last {
                return Problem(
                    location: open.location,
                    length: open.name.utf16.count + 1,
                    message: "The tag <\(open.name)> is never closed"
                )
            }

            return nil
        }
    }

    private final class Collector: NSObject, XMLParserDelegate {
        var root: String?

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            if root == nil { root = elementName }
        }
    }

    /// A property list must also make sense as one.
    private static func propertyListProblems(
        _ data: Data,
        root: String?,
        text: [UInt16],
        fileName: String
    ) -> [DocumentDiagnostic] {
        guard root == "plist" else { return [] }

        do {
            _ = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)

            return []
        } catch {
            let start = Array("<plist".utf16)
            let location = (0...max(0, text.count - start.count)).first {
                $0 + start.count <= text.count && Array(text[$0..<($0 + start.count)]) == start
            } ?? 0

            return [DocumentDiagnostic(
                range: UTF16TextRange(location: location, length: min(6, max(0, text.count - location))),
                severity: .error,
                message: "Not a valid property list: \((error as NSError).localizedDescription)",
                source: "plist"
            )]
        }
    }

    /// The UTF-16 offset of a line and column the parser counted (the column in UTF-8 bytes).
    private static func offset(ofLine line: Int, column: Int, in text: [UInt16]) -> Int {
        var start = 0
        var current = 1
        var index = 0
        while index < text.count, current < line {
            if text[index] == 0x0A {
                current += 1
                start = index + 1
            }
            else if text[index] == 0x0D {
                current += 1
                start = index + ((index + 1 < text.count && text[index + 1] == 0x0A) ? 2 : 1)
            }

            index += 1
        }

        var bytes = 0
        var cursor = start
        while cursor < text.count, text[cursor] != 0x0A, text[cursor] != 0x0D, bytes < column - 1 {
            let unit = text[cursor]
            bytes += unit < 0x80 ? 1 : (unit < 0x800 ? 2 : 3)
            cursor += 1
        }

        // The parser reports where it stopped, which is just past the offending character.
        return max(start, min(text.count, cursor > start ? cursor - 1 : cursor))
    }
}

// MARK: Formatting

public struct FormattingError: Error, Equatable {
    public let message: String

    public init(_ message: String) { self.message = message }
}

/// Re-indents the languages that have one agreed layout: JSON (two spaces; the order of the keys and the
/// spelling of numbers are kept) and XML.
public enum DocumentFormatting {
    public static func supports(_ language: DocumentLanguage) -> Bool {
        language == .json || language == .xml || language == .toml
    }

    public static func format(_ text: String, language: DocumentLanguage) throws -> String {
        switch language {
        case .json: try formatJSON(text)
        case .xml: try formatXML(text)
        case .toml: try formatTOML(text)
        default: throw FormattingError("\(language.displayName) cannot be formatted")
        }
    }

    // MARK: JSON

    static func formatJSON(_ source: String) throws -> String {
        let text = Array(source.utf16)
        if let problem = JSONSyntax(text).check().first {
            throw FormattingError(problem.severity == .error
                ? "Fix the error first: \(problem.message)"
                : problem.message
                    + "; formatting would remove it")
        }

        var output: [UInt16] = []
        var depth = 0
        var index = 0

        func newline() {
            output.append(0x0A)
            output.append(contentsOf: [UInt16](repeating: 0x20, count: depth * 2))
        }

        func nextSignificant(after position: Int) -> UInt16? {
            var scan = position
            while scan < text.count {
                if text[scan] != 0x20, text[scan] != 0x09, text[scan] != 0x0A, text[scan] != 0x0D { return text[scan] }

                scan += 1
            }

            return nil
        }

        while index < text.count {
            let unit = text[index]
            switch unit {
            case 0x20, 0x09, 0x0A, 0x0D:
                index += 1
            case 0x22:
                let start = index
                index += 1
                while index < text.count, text[index] != 0x22 { index += text[index] == 0x5C ? 2 : 1 }

                index += 1
                output.append(contentsOf: text[start..<min(index, text.count)])
            case 0x7B, 0x5B:
                output.append(unit)
                index += 1
                let closer: UInt16 = unit == 0x7B ? 0x7D : 0x5D
                if nextSignificant(after: index) == closer {
                    while text[index] != closer { index += 1 }

                    output.append(closer)
                    index += 1
                } else {
                    depth += 1
                    newline()
                }
            case 0x7D, 0x5D:
                depth -= 1
                newline()
                output.append(unit)
                index += 1
            case 0x2C:
                output.append(unit)
                newline()
                index += 1
            case 0x3A:
                output.append(contentsOf: [0x3A, 0x20])
                index += 1
            default:
                let start = index
                while index < text.count, ![0x20, 0x09, 0x0A, 0x0D, 0x2C, 0x5D, 0x7D, 0x3A].contains(text[index]) {
                    index += 1
                }

                output.append(contentsOf: text[start..<index])
            }
        }
        output.append(0x0A)

        return String(decoding: output, as: UTF16.self)
    }

    // MARK: XML

    static func formatXML(_ source: String) throws -> String {
        if let problem = SyntaxChecks.check(Array(source.utf16), language: .xml)
            .first(where: { $0.severity == .error }) {
            throw FormattingError("Fix the error first: \(problem.message)")
        }

        let document: XMLDocument
        do {
            document = try XMLDocument(
                data: Data(source.utf8),
                options: [.nodePreserveCDATA, .nodePreserveCharacterReferences]
            )
        } catch {
            throw FormattingError("The XML could not be read: \(error.localizedDescription)")
        }

        var body = document.xmlString(options: [
            .nodePrettyPrint,
            .nodeCompactEmptyElement,
            .nodePreserveCDATA,
            .nodePreserveCharacterReferences
        ])
        // Foundation writes its own declaration, and adds `standalone="yes"` the second time round:
        // the declaration of the file is the user's, so it is kept as written, or left out if there was none.
        let declaration = try? NSRegularExpression(pattern: #"^\s*<\?xml[^>]*\?>\s*"#)

        func split(_ text: String) -> (String?, String) {
            let range = NSRange(location: 0, length: (text as NSString).length)
            guard let match = declaration?.firstMatch(in: text, range: range) else { return (nil, text) }

            let found = (text as NSString).substring(with: match.range).trimmingCharacters(in: .whitespacesAndNewlines)

            return (found, (text as NSString).substring(from: match.range.upperBound))
        }

        body = split(body).1
        let original = split(source).0
        let result = (original.map { $0 + "\n" } ?? "") + body

        return result.hasSuffix("\n") ? result : result + "\n"
    }
}

extension DocumentFormatting {
    /// The one edit that turns `old` into `new`: the part between their common beginning and end, so
    /// that a caret and a scroll position outside it stay where they are. nil if they are the same.
    public static func minimalEdit(from old: String, to new: String) -> DocumentEdit? {
        let before = Array(old.utf16), after = Array(new.utf16)
        var prefix = 0
        while prefix < before.count, prefix < after.count, before[prefix] == after[prefix] { prefix += 1 }

        var suffix = 0
        while suffix < before.count - prefix, suffix < after.count - prefix,
              before[before.count - 1 - suffix] == after[after.count - 1 - suffix] { suffix += 1 }

        guard prefix + suffix < before.count || prefix + suffix < after.count else { return nil }

        // Do not cut a surrogate pair in two.
        if prefix > 0, UTF16.isLeadSurrogate(before[prefix - 1]) { prefix -= 1 }

        let removed = before.count - prefix - suffix
        let inserted = String(decoding: after[prefix..<(after.count - suffix)], as: UTF16.self)

        return DocumentEdit(range: UTF16TextRange(location: prefix, length: removed), replacement: inserted)
    }
}

// MARK: Who checks what

/// Something that finds problems in a language's text. The editor asks every one it has; each answers
/// for its own languages.
public protocol SyntaxChecking: Sendable {
    func supports(_ language: DocumentLanguage) -> Bool

    /// `directory` is the folder the document is in, for checkers that read the files it names.
    func check(
        _ text: [UInt16],
        language: DocumentLanguage,
        fileName: String,
        directory: String?
    ) async -> [DocumentDiagnostic]
}

/// The checks that need nothing outside this module: JSON, XML and property lists, TOML.
public struct BuiltInChecker: SyntaxChecking {
    public init() {}

    public func supports(_ language: DocumentLanguage) -> Bool { SyntaxChecks.supports(language) }

    public func check(
        _ text: [UInt16],
        language: DocumentLanguage,
        fileName: String,
        directory: String?
    ) async -> [DocumentDiagnostic] {
        SyntaxChecks.check(text, language: language, fileName: fileName)
    }
}

/// Several checkers as one: the first that supports the language answers.
public struct CompositeChecker: SyntaxChecking {
    private let checkers: [any SyntaxChecking]

    public init(_ checkers: [any SyntaxChecking]) { self.checkers = checkers }

    public func supports(_ language: DocumentLanguage) -> Bool { checkers.contains { $0.supports(language) } }

    public func check(
        _ text: [UInt16],
        language: DocumentLanguage,
        fileName: String,
        directory: String?
    ) async -> [DocumentDiagnostic] {
        guard let checker = checkers.first(where: { $0.supports(language) }) else { return [] }

        return await checker.check(text, language: language, fileName: fileName, directory: directory)
    }
}

// MARK: Who formats what

/// Something that lays out a language's text. The editor asks the formatters it has.
public protocol DocumentFormatter: Sendable {
    func supports(_ language: DocumentLanguage) -> Bool

    /// The text laid out, or why it was left alone.
    func format(_ text: String, language: DocumentLanguage) throws -> String
}

/// The formatting that needs nothing outside this module: JSON, XML and property lists, TOML.
public struct BuiltInFormatter: DocumentFormatter {
    public init() {}

    public func supports(_ language: DocumentLanguage) -> Bool { DocumentFormatting.supports(language) }

    public func format(_ text: String, language: DocumentLanguage) throws -> String {
        try DocumentFormatting.format(text, language: language)
    }
}

public struct CompositeFormatter: DocumentFormatter {
    private let formatters: [any DocumentFormatter]

    public init(_ formatters: [any DocumentFormatter]) { self.formatters = formatters }

    public func supports(_ language: DocumentLanguage) -> Bool { formatters.contains { $0.supports(language) } }

    public func format(_ text: String, language: DocumentLanguage) throws -> String {
        guard let formatter = formatters.first(where: { $0.supports(language) }) else {
            throw FormattingError("\(language.displayName) cannot be formatted")
        }

        return try formatter.format(text, language: language)
    }
}
