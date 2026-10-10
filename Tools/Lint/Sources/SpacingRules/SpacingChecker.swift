import Foundation
import SwiftParser
import SwiftParserDiagnostics
import SwiftSyntax

/// A place where a rule is not met.
public struct Violation: Equatable, Sendable {
    public let path: String
    public let line: Int
    public let column: Int
    public let rule: Rule
    public let message: String

    /// `path:line:column: error: [rule] message`, the form editors and CI understand.
    public var formatted: String { "\(path):\(line):\(column): error: [\(rule.rawValue)] \(message)" }
}

public enum Rule: String, CaseIterable, Sendable {
    case blankLineBeforeReturn = "blank_line_before_return"
    case blankLineAfterMultilineIf = "blank_line_after_multiline_if"
}

/// The two blank-line rules of TK-023, found in the syntax tree, never in the text.
///
/// - A `return` that follows other statements of the same block has a blank line before it.
/// - A multi-line `if` (with its `else if` / `else`) that is followed by more statements of the
///   same block has a blank line after it.
///
/// A comment directly above the statement belongs to it: the blank line goes above the comment.
/// The first statement of a block, a statement on the same line as the one before, and
/// single-line `if`s in a row need nothing.
public enum SpacingChecker {
    /// The violations in `source`, in source order.
    public static func check(_ source: String, path: String = "<source>") -> [Violation] {
        let tree = Parser.parse(source: source)
        return find(in: tree, path: path).map(\.violation).sorted { ($0.line, $0.column) < ($1.line, $1.column) }
    }

    /// `source` with the missing blank lines added, or nil when none is missing. Throws if the
    /// result would not be the same code: tokens and comments are compared, and the result may not
    /// have more syntax errors than the original.
    public static func fix(_ source: String, path: String = "<source>") throws -> String? {
        let tree = Parser.parse(source: source)
        let found = find(in: tree, path: path)
        guard !found.isEmpty else { return nil }

        let fixed = Inserter(ids: Set(found.map(\.itemID))).rewrite(tree)
        let output = fixed.description
        try verify(original: source, fixed: output, path: path)
        return output
    }

    public struct FixRefused: Error, CustomStringConvertible {
        public let path: String
        public let reason: String
        public var description: String { "\(path): refused to write the fix: \(reason)" }
    }

    // MARK: Finding

    fileprivate struct Found {
        let itemID: SyntaxIdentifier
        let violation: Violation
    }

    private static func find(in tree: SourceFileSyntax, path: String) -> [Found] {
        let finder = Finder(converter: SourceLocationConverter(fileName: path, tree: tree), path: path)
        finder.walk(tree)
        return finder.found
    }

    /// Throws unless `fixed` is `original` with only blank lines added.
    static func verify(original originalSource: String, fixed fixedSource: String, path: String) throws {
        let original = Parser.parse(source: originalSource)
        let fixed = Parser.parse(source: fixedSource)
        func shape(_ tree: SourceFileSyntax) -> (tokens: [String], comments: [String]) {
            var tokens: [String] = [], comments: [String] = []
            for token in tree.tokens(viewMode: .sourceAccurate) {
                tokens.append(token.text)
                for piece in token.leadingTrivia + token.trailingTrivia {
                    if let text = piece.commentText { comments.append(text) }
                }
            }
            return (tokens, comments)
        }
        let before = shape(original), after = shape(fixed)
        guard before.tokens == after.tokens else { throw FixRefused(path: path, reason: "the tokens changed") }

        guard before.comments == after.comments else { throw FixRefused(path: path, reason: "the comments changed") }

        let errors = { (tree: SourceFileSyntax) in ParseDiagnosticsGenerator.diagnostics(for: tree).count }
        guard errors(fixed) <= errors(original) else { throw FixRefused(path: path, reason: "the result has more syntax errors") }
    }

    private final class Finder: SyntaxVisitor {
        let converter: SourceLocationConverter
        let path: String
        var found: [Found] = []

        init(converter: SourceLocationConverter, path: String) {
            self.converter = converter
            self.path = path
            super.init(viewMode: .sourceAccurate)
        }

        override func visit(_ node: CodeBlockItemListSyntax) -> SyntaxVisitorContinueKind {
            let items = Array(node)
            for index in items.indices where index > 0 {
                let item = items[index]
                if item.isReturn {
                    report(.blankLineBeforeReturn, item, "put a blank line before `return` when other statements come before it in the block")
                } else if isMultilineIf(items[index - 1]) {
                    report(.blankLineAfterMultilineIf, item, "put a blank line after a multi-line `if` when the block goes on")
                }
            }
            return .visitChildren
        }

        private func report(_ rule: Rule, _ item: CodeBlockItemSyntax, _ message: String) {
            let leading = item.firstToken(viewMode: .sourceAccurate)?.leadingTrivia ?? []
            guard BlankLines.insertionPoint(in: Array(leading)) != nil else { return }

            let location = converter.location(for: item.positionAfterSkippingLeadingTrivia)
            found.append(Found(
                itemID: item.id,
                violation: Violation(path: path, line: location.line, column: location.column, rule: rule, message: message)
            ))
        }

        private func isMultilineIf(_ item: CodeBlockItemSyntax) -> Bool {
            guard item.isIf else { return false }

            let start = converter.location(for: item.positionAfterSkippingLeadingTrivia)
            let end = converter.location(for: item.endPositionBeforeTrailingTrivia)
            return end.line > start.line
        }
    }

    // MARK: Fixing

    private final class Inserter: SyntaxRewriter {
        let ids: Set<SyntaxIdentifier>

        init(ids: Set<SyntaxIdentifier>) {
            self.ids = ids
            super.init(viewMode: .sourceAccurate)
        }

        override func visit(_ node: CodeBlockItemSyntax) -> CodeBlockItemSyntax {
            var result = super.visit(node)
            guard ids.contains(node.id), let token = result.firstToken(viewMode: .sourceAccurate) else { return result }

            let pieces = Array(token.leadingTrivia)
            guard let index = BlankLines.insertionPoint(in: pieces) else { return result }

            var changed = pieces
            changed[index] = changed[index].oneNewlineMore
            result.leadingTrivia = Trivia(pieces: changed)
            return result
        }
    }
}

// MARK: Blank lines in trivia

enum BlankLines {
    /// Where one more line break would give the statement its blank line: the index of the single
    /// line break that ends the line above the statement and its comments. Nil when the statement
    /// already has the blank line, or is on the line of the code before it.
    static func insertionPoint(in pieces: [TriviaPiece]) -> Int? {
        var cursor = pieces.count
        skipSpaces(pieces, &cursor)
        while true {
            // Line breaks directly above the line that starts at `cursor`.
            guard cursor > 0, pieces[cursor - 1].newlineCount > 0 else { return nil }

            var breaks = 0
            var last = cursor - 1
            while last >= 0, pieces[last].newlineCount > 0 {
                breaks += pieces[last].newlineCount
                last -= 1
            }
            if breaks >= 2 { return nil }

            var above = cursor - 1
            skipSpaces(pieces, &above)
            if above > 0, pieces[above - 1].newlineCount > 0 { return nil }   // a line with only spaces: blank

            guard above > 0, pieces[above - 1].isComment else { return cursor - 1 }

            // A comment line directly above belongs to the statement: look above the comment.
            var commentLine = above - 1
            skipSpaces(pieces, &commentLine)
            cursor = commentLine
        }
    }

    private static func skipSpaces(_ pieces: [TriviaPiece], _ cursor: inout Int) {
        while cursor > 0, pieces[cursor - 1].isSpace { cursor -= 1 }
    }
}

private extension TriviaPiece {
    var newlineCount: Int {
        switch self {
        case .newlines(let n), .carriageReturns(let n), .carriageReturnLineFeeds(let n): n
        default: 0
        }
    }

    var isSpace: Bool {
        switch self {
        case .spaces, .tabs, .verticalTabs, .formfeeds: true
        default: false
        }
    }

    var isComment: Bool {
        switch self {
        case .lineComment, .blockComment, .docLineComment, .docBlockComment: true
        default: false
        }
    }

    var commentText: String? {
        switch self {
        case .lineComment(let text), .blockComment(let text), .docLineComment(let text), .docBlockComment(let text): text
        default: nil
        }
    }

    var oneNewlineMore: TriviaPiece {
        switch self {
        case .newlines(let n): .newlines(n + 1)
        case .carriageReturns(let n): .carriageReturns(n + 1)
        case .carriageReturnLineFeeds(let n): .carriageReturnLineFeeds(n + 1)
        default: self
        }
    }
}

private extension CodeBlockItemSyntax {
    var isReturn: Bool {
        if case .stmt(let statement) = item { return statement.is(ReturnStmtSyntax.self) }
        return false
    }

    var isIf: Bool {
        switch item {
        case .expr(let expression): expression.is(IfExprSyntax.self)
        case .stmt(let statement): statement.as(ExpressionStmtSyntax.self)?.expression.is(IfExprSyntax.self) ?? false
        case .decl: false
        }
    }
}
