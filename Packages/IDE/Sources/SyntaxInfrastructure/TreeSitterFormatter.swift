import Foundation
import IDEApplication
import IDEDomain
import SwiftTreeSitter

/// Lays out YAML and shell scripts. Both only change white space: indentation (to two spaces a level),
/// trailing blanks, runs of blank lines and the last line break. What a file says is protected twice:
/// the text of heredocs, block scalars and multi-line strings is not touched, and afterwards the result
/// is parsed again and must have exactly the same syntax tree as the original; if it does not, the file
/// is left alone and the user is told so.
public struct TreeSitterFormatter: DocumentFormatter {
    public init() {}

    public func supports(_ language: DocumentLanguage) -> Bool { language == .yaml || language == .shell }

    public func format(_ text: String, language: DocumentLanguage) throws -> String {
        guard let grammar = TreeSitterChecks.grammar(for: language) else {
            throw FormattingError("\(language.displayName) cannot be formatted")
        }

        let before = try Parsed(text, grammar: grammar)
        let formatted: String
        switch language {
        case .yaml: formatted = try YAMLLayout(before).result()
        default: formatted = try ShellLayout(before).result()
        }

        let after = try Parsed(formatted, grammar: grammar)
        guard after.fingerprint == before.fingerprint else {
            throw FormattingError("Formatting would change what the file says, so it was left alone")
        }

        return formatted
    }
}

// MARK: A parsed text

/// A text, its tree and what is needed to talk about lines.
struct Parsed {
    let text: String
    let units: [UInt16]
    let root: Node
    let lineStarts: [Int]
    private let tree: MutableTree

    init(_ text: String, grammar: Language) throws {
        let parser = Parser()
        try parser.setLanguage(grammar)
        guard let tree = parser.parse(text), let root = tree.rootNode else {
            throw FormattingError("The text could not be read")
        }

        guard !root.hasError else { throw FormattingError("Fix the errors in the file first") }

        self.text = text
        units = Array(text.utf16)
        self.tree = tree
        self.root = root
        var starts = [0]
        var index = 0
        while index < units.count {
            if units[index] == 0x0A { starts.append(index + 1) }
            else if units[index] == 0x0D {
                index += (index + 1 < units.count && units[index + 1] == 0x0A) ? 1 : 0
                starts.append(index + 1)
            }

            index += 1
        }
        lineStarts = starts
    }

    var lineCount: Int { lineStarts.count }

    func line(containing offset: Int) -> Int {
        var low = 0, high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= offset { low = mid } else { high = mid - 1 }
        }

        return low
    }

    /// The lines of the text without their terminators.
    var lines: [String] {
        lineStarts.indices.map { number in
            var end = number + 1 < lineStarts.count ? lineStarts[number + 1] : units.count
            while end > lineStarts[number], units[end - 1] == 0x0A || units[end - 1] == 0x0D { end -= 1 }

            return String(decoding: units[lineStarts[number]..<end], as: UTF16.self)
        }
    }

    /// The syntax tree as a string: the kind of every node, and the text of the leaves with their white
    /// space made one space. Two texts with the same fingerprint say the same thing.
    var fingerprint: String {
        var pieces: [String] = []
        var stack: [Node] = [root]
        while let node = stack.popLast() {
            pieces.append(node.nodeType ?? "?")
            if node.childCount == 0 {
                let range = Int(node.byteRange.lowerBound) / 2..<Int(node.byteRange.upperBound) / 2
                let leaf = String(
                    decoding: units[range.lowerBound..<min(range.upperBound, units.count)],
                    as: UTF16.self
                )
                pieces.append(leaf.split(whereSeparator: \.isWhitespace).joined(separator: " "))
            } else {
                for index in (0..<node.childCount).reversed() {
                    if let child = node.child(at: index) { stack.append(child) }
                }
            }
        }

        return pieces.joined(separator: "\u{1}")
    }

    /// The numbers of the first and last line a node covers.
    func lines(of node: Node) -> ClosedRange<Int> {
        let start = Int(node.byteRange.lowerBound) / 2
        let end = max(start, Int(node.byteRange.upperBound) / 2 - 1)

        return line(containing: start)...line(containing: min(end, max(0, units.count - 1)))
    }

    /// Every node of the given kinds.
    func nodes(ofKinds kinds: Set<String>) -> [Node] {
        var found: [Node] = []
        var stack: [Node] = [root]
        while let node = stack.popLast() {
            if let type = node.nodeType, kinds.contains(type) { found.append(node) }

            for index in 0..<node.childCount {
                if let child = node.child(at: index) { stack.append(child) }
            }
        }

        return found
    }

    /// The terminator the text uses most.
    var terminator: String { text.contains("\r\n") ? "\r\n" : "\n" }
}

// MARK: YAML

private struct YAMLLayout {
    let source: Parsed

    init(_ source: Parsed) { self.source = source }

    func result() throws -> String {
        let lines = source.lines
        var bodies: [Int: Int] = [:]   // body line -> the line that owns the block scalar
        var owners: [Int: [Int]] = [:]
        for node in source.nodes(ofKinds: ["block_scalar"]) {
            let covered = source.lines(of: node)
            let header = covered.lowerBound
            // An explicit indentation indicator (`|2`) ties the text to a column: not moved.
            let headerText = lines[header]
            if headerText.contains(where: { "|>".contains($0) }),
               let indicator = headerText.firstIndex(where: { $0 == "|" || $0 == ">" }),
               headerText[headerText.index(after: indicator)...].prefix(3).contains(where: \.isNumber) {
                throw FormattingError("A block scalar with an indentation indicator is left as it is")
            }

            for line in (header + 1)...max(header + 1, covered.upperBound)
                where line <= covered.upperBound && line < lines.count {
                bodies[line] = header
                owners[header, default: []].append(line)
            }
        }

        var newIndent = [Int](repeating: 0, count: lines.count)
        var stack: [Int] = []
        var lastBlank = true
        for (number, line) in lines.enumerated() {
            if bodies[number] != nil { continue }

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            let indent = line.prefix { $0 == " " }.count
            if trimmed.hasPrefix("---") || trimmed.hasPrefix("...") {
                stack = []
                newIndent[number] = 0

                continue
            }

            if trimmed.hasPrefix("#") {
                let level = max(0, stack.filter { $0 <= indent }.count - 1)
                newIndent[number] = level * 2

                continue
            }

            while let top = stack.last, top > indent { stack.removeLast() }

            if stack.last != indent { stack.append(indent) }

            newIndent[number] = (stack.count - 1) * 2
        }

        var result: [String] = []
        for (number, line) in lines.enumerated() {
            if bodies[number] != nil { continue }

            var trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                if !lastBlank { result.append("") }

                lastBlank = true

                continue
            }

            lastBlank = false
            trimmed = collapseDashSpaces(trimmed)
            let text = String(repeating: " ", count: newIndent[number]) + trimmed
            result.append(text)
            // The body of a block scalar moves with the line that owns it.
            if let body = owners[number] {
                let content = body.map { lines[$0] }.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                let smallest = content.map { $0.prefix { $0 == " " }.count }.min() ?? 0
                // The text belongs to a key, which stands after any dashes; or to the last dash itself
                // when the item is only the block scalar ("- |").
                let dashes = leadingDashColumns(trimmed)
                let onlyScalar = trimmed.dropFirst(dashes).first.map { $0 == "|" || $0 == ">" } ?? false
                let keyColumn = newIndent[number] + (onlyScalar ? max(0, dashes - 2) : dashes)
                let delta = keyColumn + 2 - smallest
                for index in body {
                    let original = lines[index]
                    if original.trimmingCharacters(in: .whitespaces).isEmpty {
                        result.append("")
                    } else {
                        let indent = original.prefix { $0 == " " }.count
                        result
                            .append(String(repeating: " ", count: max(0, indent + delta)) + original.dropFirst(indent))
                    }
                }
            }
        }

        while result.last?.isEmpty == true { result.removeLast() }

        return result.joined(separator: source.terminator) + source.terminator
    }

    /// `-    item` as `- item`.
    private func collapseDashSpaces(_ line: String) -> String {
        var rest = Substring(line)
        var prefix = ""
        while rest.hasPrefix("- ") {
            prefix += "- "
            rest = rest.dropFirst(2).drop { $0 == " " }
        }

        return prefix + rest
    }

    /// The width of the dashes a line starts with ("- - " is 4).
    private func leadingDashColumns(_ trimmed: String) -> Int {
        var count = 0
        var rest = Substring(trimmed)
        while rest.hasPrefix("- ") {
            count += 2
            rest = rest.dropFirst(2)
        }

        return count
    }
}

// MARK: Shell

private struct ShellLayout {
    let source: Parsed

    init(_ source: Parsed) { self.source = source }

    func result() throws -> String {
        let lines = source.lines
        var protected = Set<Int>()
        for node in source.nodes(ofKinds: ["heredoc_body", "heredoc_end", "string", "raw_string", "ansi_c_string"]) {
            let covered = source.lines(of: node)
            // A string that starts on a line protects the lines after it; a heredoc, all of its own.
            let first = node.nodeType?.hasPrefix("heredoc") == true ? covered.lowerBound : covered.lowerBound + 1
            if first <= covered.upperBound { for line in first...covered.upperBound { protected.insert(line) } }
        }

        var depth = 0
        var caseDepths: [Int] = []
        var result: [String] = []
        var lastBlank = true
        var previousContinues = false
        for (number, line) in lines.enumerated() {
            if protected.contains(number) || previousContinues {
                result.append(line)
                lastBlank = false
                previousContinues = !protected.contains(number) && line.trimmingCharacters(in: .whitespaces)
                    .hasSuffix("\\")

                continue
            }

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                if !lastBlank { result.append("") }

                lastBlank = true

                continue
            }

            lastBlank = false
            previousContinues = trimmed.hasSuffix("\\")
            if trimmed.hasPrefix("#") {
                result.append(String(repeating: "  ", count: depth) + trimmed)

                continue
            }

            let words = Self.words(of: trimmed)
            var leadingDedent = 0
            if let first = words.first {
                if ["fi", "done", "esac", "}", "else", "elif", "then", "do"].contains(first) { leadingDedent = 1 }
            }

            var change = 0
            var previousIsSeparator = true
            for word in words {
                if previousIsSeparator {
                    if ["if", "for", "while", "until", "select"].contains(word) { change += 1 }

                    if word == "case" {
                        change += 1
                        caseDepths.append(depth + change)
                    }

                    if ["fi", "done"].contains(word) { change -= 1 }

                    if word == "esac" {
                        change -= 1
                        _ = caseDepths.popLast()
                    }

                }

                // A brace on its own is a group or the body of a function wherever it stands.
                if word == "{" { change += 1 }

                if word == "}" { change -= 1 }

                previousIsSeparator = Self.separators.contains(word)
            }
            // `;;` ends a branch of a case; a line that names a branch opens one.
            var indentDepth = depth - leadingDedent
            if let caseDepth = caseDepths.last, depth == caseDepth, Self.isCasePattern(trimmed) {
                indentDepth = depth
                if !trimmed.contains(";;") { change += 1 }
            } else if trimmed.hasPrefix(";;") {
                change -= 1
            } else if trimmed.contains(";;"), let caseDepth = caseDepths.last, depth > caseDepth {
                change -= 1
            }

            guard indentDepth >= 0, depth + change >= 0 else {
                throw FormattingError("The structure of the script could not be followed, so it was left alone")
            }

            result.append(String(repeating: "  ", count: indentDepth) + trimmed)
            depth += change
        }

        guard depth == 0 else {
            throw FormattingError("The structure of the script could not be followed, so it was left alone")
        }

        while result.last?.isEmpty == true { result.removeLast() }

        return result.joined(separator: source.terminator) + source.terminator
    }

    private static let separators: Set<String> = [
        ";",
        "|",
        "&&",
        "||",
        "&",
        "(",
        "{",
        "then",
        "do",
        "else",
        "elif",
        "!",
        ";;"
    ]

    private static let casePattern = try! NSRegularExpression(pattern: #"^\(?[^\s()]*(\|[^\s()]*)*\)"#)

    /// `*.txt)` or `a|b)` at the start of a line inside a case.
    private static func isCasePattern(_ line: String) -> Bool {
        casePattern.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil
    }

    /// The words of a line that are in command position or are separators, with what is quoted and
    /// what is a comment left out.
    private static func words(of line: String) -> [String] {
        var cleaned = ""
        var quote: Character?
        for character in line {
            if let open = quote {
                if character == open { quote = nil }

                continue
            }

            if character == "\"" || character == "'" {
                quote = character
                cleaned.append(" ")
                continue
            }

            if character == "#", cleaned.last == nil || cleaned.last == " " || cleaned.last == "\t" { break }

            cleaned.append(character)
        }

        var words: [String] = []
        var word = ""

        func flush() {
            if !word.isEmpty { words.append(word) }

            word = ""
        }

        let characters = Array(cleaned)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == " " || character == "\t" {
                flush()
            } else if character == ";" || character == "|" || character == "&" || character == "(" || character == "{" {
                flush()
                if index + 1 < characters.count, characters[index + 1] == character,
                   character == "&" || character == "|" || character == ";" {
                    words.append(String([character, character]))
                    index += 1
                } else {
                    words.append(String(character))
                }
            } else if character == "}" || character == ")" {
                flush()
                words.append(String(character))
            } else {
                word.append(character)
            }

            index += 1
        }
        flush()

        return words
    }
}
