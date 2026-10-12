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
    case blankLineAroundInitializer = "blank_line_around_initializer"
    case blankLineAroundFunction = "blank_line_around_function"
    case multipleStatementBody = "multiple_statement_body"
    case separateStatements = "one_statement_per_line"
    case longLineBody = "long_line_body"
    case longLineStatements = "long_line_statements"
}

/// The spacing and instruction-layout rules of TK-023, found in the syntax tree.
///
/// - A `return` that follows other statements of the same block has a blank line before it.
/// - A multi-line `if` (with its `else if` / `else`) that is followed by more statements of the
///   same block has a blank line after it.
///
/// - Initializers and functions are separated from their neighbors, including attributes/comments.
///   A first/last member needs no extra blank line against the containing braces.
///
/// - A block written as `{ statements }` on a line longer than `maxLineLength` has its body on lines of its
///   own and its `}` on a line of its own, so a formatter wraps the statement's header no more than it must,
///   never the header with the body left behind it. Of the blocks that close their line, the outermost one,
///   the last on the line, is expanded, and so on until the line fits or no such block is left.
/// - Multiple inline instructions/declarations expand their containing body. Statements joined with
///   `;` each get their own line, even on short lines. Required control-flow separators are preserved.
///
/// A comment directly above the statement belongs to it: the blank line goes above the comment.
/// First/last declarations need no blank line against their containing braces. Single-instruction
/// short bodies may stay inline; adjacent short `if`s need no blank line between them.
public enum SpacingChecker {
    /// The longest line, in characters; `--max-width` of `.swiftformat` and `line_length` of `.swiftlint.yml`.
    public static let maxLineLength = 120

    /// The violations in `source`, in source order.
    public static func check(_ source: String, path: String = "<source>") -> [Violation] {
        let tree = Parser.parse(source: source)
        let all = find(in: tree, path: path) + findBodies(in: tree, source: source, path: path)
            + findStatements(in: tree, source: source, path: path)
        return all.map(\.violation).sorted { ($0.line, $0.column) < ($1.line, $1.column) }
    }

    /// `source` with spacing and instruction layout corrected, or nil when unchanged. Before writing,
    /// verifies tokens, comments, statement grouping, control flow and the syntax-error count.
    public static func fix(_ source: String, path: String = "<source>") throws -> String? {
        var current = source
        // Expanding a body can leave the line still too long, with another block on it.
        for _ in 0..<16 {
            let tree = Parser.parse(source: current)
            // The bodies first: a block that closes a long line is put on lines of its own before the `;`
            // inside it are looked at, or its statements would be split while the block is still on one line.
            let bodies = findBodies(in: tree, source: current, path: path)
            if !bodies.isEmpty {
                current = BodyExpander(ids: Set(bodies.map(\.itemID))).rewrite(tree).description
                continue
            }
            let joined = findStatements(in: tree, source: current, path: path)
            guard !joined.isEmpty else { break }

            current = StatementSplitter(ids: Set(joined.map(\.itemID))).rewrite(tree).description
        }
        let tree = Parser.parse(source: current)
        let found = find(in: tree, path: path)
        if !found.isEmpty { current = Inserter(ids: Set(found.map(\.itemID))).rewrite(tree).description }
        guard current != source else { return nil }

        try verify(original: source, fixed: current, path: path)
        return current
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

    private static func trimTrailingSpaces(_ trivia: Trivia) -> Trivia {
        var pieces = Array(trivia)
        while pieces.last?.isSpace == true { pieces.removeLast() }
        return Trivia(pieces: pieces)
    }

    /// Throws unless `fixed` is `original` with only line breaks, indentation and `;` between statements changed.
    static func verify(original originalSource: String, fixed fixedSource: String, path: String) throws {
        let original = Parser.parse(source: originalSource)
        let fixed = Parser.parse(source: fixedSource)
        func shape(_ tree: SourceFileSyntax) -> (tokens: [String], comments: [String]) {
            var tokens: [String] = [], comments: [String] = []
            for token in tree.tokens(viewMode: .sourceAccurate) {
                // A `;` between statements goes when they are put on lines of their own.
                if token.tokenKind != .semicolon { tokens.append(token.text) }
                for piece in token.leadingTrivia + token.trailingTrivia {
                    if let text = piece.commentText { comments.append(text) }
                }
            }
            return (tokens, comments)
        }
        let before = shape(original), after = shape(fixed)
        guard before.tokens == after.tokens else { throw FixRefused(path: path, reason: "the tokens changed") }

        guard before.comments == after.comments else { throw FixRefused(path: path, reason: "the comments changed") }

        let beforeGrouping = StatementGrouping()
        beforeGrouping.walk(original)
        let afterGrouping = StatementGrouping()
        afterGrouping.walk(fixed)
        guard beforeGrouping.shape == afterGrouping.shape else {
            throw FixRefused(path: path, reason: "statement grouping or control flow changed")
        }

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
                if item.item.as(InitializerDeclSyntax.self) != nil || items[index - 1].item.as(InitializerDeclSyntax.self) != nil {
                    report(.blankLineAroundInitializer, item, "put a blank line between an initializer and neighboring declarations")
                } else if item.item.is(FunctionDeclSyntax.self) || items[index - 1].item.is(FunctionDeclSyntax.self) {
                    report(.blankLineAroundFunction, item, "put a blank line between a function and neighboring declarations or statements")
                } else if item.isReturn {
                    report(.blankLineBeforeReturn, item, "put a blank line before `return` when other statements come before it in the block")
                } else if isMultilineIf(items[index - 1]) {
                    report(.blankLineAfterMultilineIf, item, "put a blank line after a multi-line `if` when the block goes on")
                }
            }
            return .visitChildren
        }

        override func visit(_ node: MemberBlockItemListSyntax) -> SyntaxVisitorContinueKind {
            let items = Array(node)
            for index in items.indices where index > 0 {
                if items[index].decl.is(InitializerDeclSyntax.self) || items[index - 1].decl.is(InitializerDeclSyntax.self) {
                    report(.blankLineAroundInitializer, items[index], "put a blank line between an initializer and neighboring declarations")
                } else if items[index].decl.is(FunctionDeclSyntax.self) || items[index - 1].decl.is(FunctionDeclSyntax.self) {
                    report(.blankLineAroundFunction, items[index], "put a blank line between a function and neighboring declarations")
                }
            }
            return .visitChildren
        }

        private func report(_ rule: Rule, _ item: some SyntaxProtocol, _ message: String) {
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

    // MARK: Long one-line bodies

    private static func findBodies(in tree: SourceFileSyntax, source: String, path: String) -> [Found] {
        let finder = BodyFinder(
            converter: SourceLocationConverter(fileName: path, tree: tree),
            lines: source.split(separator: "\n", omittingEmptySubsequences: false),
            path: path
        )
        finder.walk(tree)
        return finder.result()
    }

    /// The blocks of `{ statements }` written on one line, on a line that is too long.
    private final class BodyFinder: SyntaxVisitor {
        struct Candidate {
            let id: SyntaxIdentifier
            let line: Int
            let column: Int
            let range: Range<AbsolutePosition>
            let rule: Rule
        }

        let converter: SourceLocationConverter
        let lines: [Substring]
        let path: String
        var candidates: [Candidate] = []

        init(converter: SourceLocationConverter, lines: [Substring], path: String) {
            self.converter = converter
            self.lines = lines
            self.path = path
            super.init(viewMode: .sourceAccurate)
        }

        override func visit(_ node: CodeBlockSyntax) -> SyntaxVisitorContinueKind {
            consider(node, node.leftBrace, node.statements.count, node.rightBrace)
            return .visitChildren
        }

        override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind {
            // `Task { … }`, `lock.withLock { … }`, `answer = { _ in … }`; one that closes its line only.
            consider(node, node.leftBrace, node.statements.count, node.rightBrace)
            return .visitChildren
        }

        override func visit(_ node: AccessorBlockSyntax) -> SyntaxVisitorContinueKind {
            if case .getter(let statements) = node.accessors {
                consider(node, node.leftBrace, statements.count, node.rightBrace)
            }
            return .visitChildren
        }

        override func visit(_ node: MemberBlockSyntax) -> SyntaxVisitorContinueKind {
            consider(node, node.leftBrace, node.members.count, node.rightBrace)
            return .visitChildren
        }

        private func consider(_ node: some SyntaxProtocol, _ left: TokenSyntax, _ statements: Int, _ right: TokenSyntax) {
            guard statements > 0 else { return }

            let open = converter.location(for: left.positionAfterSkippingLeadingTrivia)
            let close = converter.location(for: right.positionAfterSkippingLeadingTrivia)
            let joined = JoinedItems(converter: converter)
            joined.walk(node)
            let first = left.nextToken(viewMode: .sourceAccurate)
            let last = right.previousToken(viewMode: .sourceAccurate)
            let compactEdge = first.map { converter.location(for: $0.positionAfterSkippingLeadingTrivia).line == open.line } == true
                || last.map { converter.location(for: $0.endPositionBeforeTrailingTrivia).line == close.line } == true
            let multiple = joined.found && compactEdge
            let long = open.line == close.line && open.line <= lines.count
                && lines[open.line - 1].count > SpacingChecker.maxLineLength
                && closesItsLine(right) && isPlain(node, left, right)
            guard multiple || long else { return }

            candidates.append(Candidate(
                id: node.id,
                line: open.line,
                column: open.column,
                range: node.positionAfterSkippingLeadingTrivia..<node.endPositionBeforeTrailingTrivia,
                rule: multiple && !long ? .multipleStatementBody : .longLineBody
            ))
        }

        /// Nothing but closing parentheses or a comma follows the `}` on its line.
        private func closesItsLine(_ right: TokenSyntax) -> Bool {
            var token = right.nextToken(viewMode: .sourceAccurate)
            while let next = token {
                if next.leadingTrivia.contains(where: { $0.isNewline }) { return true }

                guard [.rightParen, .comma, .rightSquare].contains(next.tokenKind) else { return false }

                token = next.nextToken(viewMode: .sourceAccurate)
            }
            return true
        }

        /// Between the braces there are no comments, and the layout is only spaces.
        private func isPlain(_ node: some SyntaxProtocol, _ left: TokenSyntax, _ right: TokenSyntax) -> Bool {
            for token in node.tokens(viewMode: .sourceAccurate) {
                let pieces = (token.id == left.id ? [] : Array(token.leadingTrivia)) +
                    (token.id == right.id ? [] : Array(token.trailingTrivia))
                if pieces.contains(where: { $0.isComment || $0.isNewline }) { return false }
            }
            return true
        }

        /// The outermost candidate of each line, the last of them.
        func result() -> [Found] {
            var chosen: [Candidate] = []
            for line in Set(candidates.map(\.line)) {
                let onLine = candidates.filter { $0.line == line }
                let outermost = onLine.filter { inner in
                    !onLine.contains { $0.id != inner.id && $0.range.contains(inner.range.lowerBound) && $0.range != inner.range }
                }
                if let last = outermost.max(by: { $0.range.lowerBound < $1.range.lowerBound }) { chosen.append(last) }
            }
            return chosen.map {
                Found(
                    itemID: $0.id,
                    violation: Violation(
                        path: path,
                        line: $0.line,
                        column: $0.column,
                        rule: $0.rule,
                        message: $0.rule == .multipleStatementBody
                            ? "put a body containing multiple inline instructions or declarations on separate lines"
                            : "the line is longer than \(SpacingChecker.maxLineLength) characters; put the body of the block on lines of its own"
                    )
                )
            }
        }
    }

    private final class JoinedItems: SyntaxVisitor {
        let converter: SourceLocationConverter
        var found = false

        init(converter: SourceLocationConverter) {
            self.converter = converter
            super.init(viewMode: .sourceAccurate)
        }

        private func consider(_ items: [Syntax]) {
            for index in items.indices where index > 0 {
                let end = converter.location(for: items[index - 1].endPositionBeforeTrailingTrivia)
                let start = converter.location(for: items[index].positionAfterSkippingLeadingTrivia)
                if start.line == end.line { found = true }
            }
        }

        override func visit(_ node: CodeBlockItemListSyntax) -> SyntaxVisitorContinueKind {
            consider(node.map { Syntax($0) })
            return .visitChildren
        }

        override func visit(_ node: MemberBlockItemListSyntax) -> SyntaxVisitorContinueKind {
            consider(node.map { Syntax($0) })
            return .visitChildren
        }
    }

    /// Puts the statements of the chosen blocks on lines of their own, and the `}` on its own line.
    private final class BodyExpander: SyntaxRewriter {
        let ids: Set<SyntaxIdentifier>
        /// The indentation of the line a block starts on: the original text, known from the first token's line.
        init(ids: Set<SyntaxIdentifier>) {
            self.ids = ids
            super.init(viewMode: .sourceAccurate)
        }

        override func visit(_ node: CodeBlockSyntax) -> CodeBlockSyntax {
            var result = super.visit(node)
            guard ids.contains(node.id) else { return result }

            let indent = Self.indentation(of: node)
            result.leftBrace = Self.withoutTrailingSpaces(result.leftBrace)
            result.statements = Self.expanded(result.statements, indent: indent)
            result.rightBrace = Self.onItsOwnLine(result.rightBrace, indent: indent)
            return result
        }

        override func visit(_ node: ClosureExprSyntax) -> ExprSyntax {
            var result = super.visit(node).cast(ClosureExprSyntax.self)
            guard ids.contains(node.id) else { return ExprSyntax(result) }

            let indent = Self.indentation(of: node)
            if var signature = result.signature {
                signature.inKeyword = Self.withoutTrailingSpaces(signature.inKeyword)
                result.signature = signature
            } else {
                result.leftBrace = Self.withoutTrailingSpaces(result.leftBrace)
            }
            result.statements = Self.expanded(result.statements, indent: indent)
            result.rightBrace = Self.onItsOwnLine(result.rightBrace, indent: indent)
            return ExprSyntax(result)
        }

        override func visit(_ node: AccessorBlockSyntax) -> AccessorBlockSyntax {
            var result = super.visit(node)
            guard ids.contains(node.id), case .getter(let statements) = result.accessors else { return result }

            let indent = Self.indentation(of: node)
            result.leftBrace = Self.withoutTrailingSpaces(result.leftBrace)
            result.accessors = .getter(Self.expanded(statements, indent: indent))
            result.rightBrace = Self.onItsOwnLine(result.rightBrace, indent: indent)
            return result
        }

        override func visit(_ node: MemberBlockSyntax) -> MemberBlockSyntax {
            var result = super.visit(node)
            guard ids.contains(node.id) else { return result }

            let indent = Self.indentation(of: node)
            result.leftBrace = Self.withoutTrailingSpaces(result.leftBrace)
            result.members = MemberBlockItemListSyntax(result.members.map { item in
                var item = item
                Self.removeSemicolon(from: &item)
                item.leadingTrivia = Self.leading(item.leadingTrivia, indent: indent + 4, node: node)
                return item
            })
            result.rightBrace = Self.onItsOwnLine(result.rightBrace, indent: indent)
            return result
        }

        /// The spaces that begin the line of the node's first token, taken from the trivia before it, or,
        /// when the token follows other code on its line, from the start of that line.
        private static func indentation(of node: some SyntaxProtocol) -> Int {
            var line = node.root.description
            let offset = node.positionAfterSkippingLeadingTrivia.utf8Offset
            let bytes = Array(line.utf8)
            var start = offset
            while start > 0, bytes[start - 1] != UInt8(ascii: "\n") { start -= 1 }
            line = String(decoding: bytes[start..<offset], as: UTF8.self)
            return line.prefix { $0 == " " }.count
        }

        private static func withoutTrailingSpaces(_ token: TokenSyntax) -> TokenSyntax {
            var token = token
            token.trailingTrivia = Trivia(pieces: token.trailingTrivia.filter { !$0.isSpace })
            return token
        }

        private static func onItsOwnLine(_ token: TokenSyntax, indent: Int) -> TokenSyntax {
            var token = token
            token.leadingTrivia = leading(token.leadingTrivia, indent: indent, node: token)
            return token
        }

        private static func leading(_ trivia: Trivia, indent: Int, node: some SyntaxProtocol) -> Trivia {
            let newline: TriviaPiece = node.root.description.contains("\r\n") ? .carriageReturnLineFeeds(1) : .newlines(1)
            let comments = trivia.drop(while: { $0.isSpace || $0.isNewline })
            return Trivia(pieces: [newline, .spaces(indent)] + comments)
        }

        private static func removeSemicolon(from item: inout MemberBlockItemSyntax) {
            if let semicolon = item.semicolon {
                item.decl.trailingTrivia = SpacingChecker.trimTrailingSpaces(item.decl.trailingTrivia + semicolon.leadingTrivia + semicolon.trailingTrivia)
                item.semicolon = nil
            }
        }

        private static func expanded(_ statements: CodeBlockItemListSyntax, indent: Int) -> CodeBlockItemListSyntax {
            let items = Array(statements)
            return CodeBlockItemListSyntax(items.enumerated().map { index, item in
                var item = item
                if !item.needsControlFlowSemicolon, let semicolon = item.semicolon {
                    item.item.trailingTrivia = SpacingChecker.trimTrailingSpaces(item.item.trailingTrivia + semicolon.leadingTrivia + semicolon.trailingTrivia)
                    item.semicolon = nil
                }
                item.leadingTrivia = leading(item.leadingTrivia, indent: indent + 4, node: statements)
                if index == items.count - 1 {
                    item.trailingTrivia = Trivia(pieces: item.trailingTrivia.filter { !$0.isSpace })
                }
                return item
            })
        }
    }

    // MARK: Statements joined on one line

    private static func findStatements(in tree: SourceFileSyntax, source: String, path: String) -> [Found] {
        let finder = StatementFinder(
            converter: SourceLocationConverter(fileName: path, tree: tree),
            lines: source.split(separator: "\n", omittingEmptySubsequences: false),
            path: path
        )
        finder.walk(tree)
        return finder.found
    }

    /// Statements after `;` on any line, or after a `case` label on a line longer than the limit.
    private final class StatementFinder: SyntaxVisitor {
        let converter: SourceLocationConverter
        let lines: [Substring]
        let path: String
        var found: [Found] = []

        init(converter: SourceLocationConverter, lines: [Substring], path: String) {
            self.converter = converter
            self.lines = lines
            self.path = path
            super.init(viewMode: .sourceAccurate)
        }

        override func visit(_ node: CodeBlockItemListSyntax) -> SyntaxVisitorContinueKind {
            for item in node {
                let location = converter.location(for: item.positionAfterSkippingLeadingTrivia)
                guard let kind = StatementSplitter.breakKind(of: item) else { continue }
                let long = location.line <= lines.count && lines[location.line - 1].count > SpacingChecker.maxLineLength
                guard long || kind == .afterSemicolon else { continue }

                found.append(Found(
                    itemID: item.id,
                    violation: Violation(
                        path: path,
                        line: location.line,
                        column: location.column,
                        rule: long ? .longLineStatements : .separateStatements,
                        message: "put each statement on a line of its own"
                    )
                ))
            }
            return .visitChildren
        }
    }

    private final class StatementSplitter: SyntaxRewriter {
        enum Kind { case afterSemicolon, afterColon }

        let ids: Set<SyntaxIdentifier>

        init(ids: Set<SyntaxIdentifier>) {
            self.ids = ids
            super.init(viewMode: .sourceAccurate)
        }

        /// Whether the item starts on the line of the code before it, and how it is joined to it.
        static func breakKind(of item: CodeBlockItemSyntax) -> Kind? {
            guard let first = item.firstToken(viewMode: .sourceAccurate),
                  let previous = first.previousToken(viewMode: .sourceAccurate),
                  !first.leadingTrivia.contains(where: { $0.isNewline }) else { return nil }

            switch previous.tokenKind {
            case .semicolon: return .afterSemicolon
            case .colon: return .afterColon
            default: return nil
            }
        }

        override func visit(_ node: SwitchCaseSyntax) -> SwitchCaseSyntax {
            var result = super.visit(node)
            guard let first = node.statements.first, ids.contains(first.id),
                  Self.breakKind(of: first) == .afterColon else { return result }

            func bare(_ token: TokenSyntax) -> TokenSyntax {
                var token = token
                token.trailingTrivia = Trivia(pieces: token.trailingTrivia.filter { !$0.isSpace })
                return token
            }
            switch result.label {
            case .case(var label):
                label.colon = bare(label.colon)
                result.label = .case(label)
            case .default(var label):
                label.colon = bare(label.colon)
                result.label = .default(label)
            }
            return result
        }

        override func visit(_ node: CodeBlockItemListSyntax) -> CodeBlockItemListSyntax {
            let items = Array(super.visit(node))
            let originals = Array(node)
            var result = items
            for index in items.indices where ids.contains(originals[index].id) {
                guard let kind = Self.breakKind(of: originals[index]) else { continue }

                var indent = Self.lineIndentation(of: originals[index])
                if kind == .afterSemicolon, index > 0 {
                    if !result[index - 1].needsControlFlowSemicolon, let semicolon = result[index - 1].semicolon {
                        result[index - 1].item.trailingTrivia = SpacingChecker.trimTrailingSpaces(result[index - 1].item.trailingTrivia + semicolon.leadingTrivia + semicolon.trailingTrivia)
                        result[index - 1].semicolon = nil
                    }
                    // Behind a `case` label on the same line, the statements are one level in.
                    var first = index - 1
                    while first > 0, Self.breakKind(of: originals[first]) == .afterSemicolon { first -= 1 }
                    if Self.breakKind(of: originals[first]) == .afterColon { indent += 4 }
                } else if kind == .afterColon {
                    indent += 4
                }
                let newline: TriviaPiece = node.root.description.contains("\r\n") ? .carriageReturnLineFeeds(1) : .newlines(1)
                let comments = result[index].leadingTrivia.drop(while: { $0.isSpace || $0.isNewline })
                result[index].leadingTrivia = Trivia(pieces: [newline, .spaces(indent)] + comments)
            }
            return CodeBlockItemListSyntax(result)
        }

        private static func lineIndentation(of node: some SyntaxProtocol) -> Int {
            let bytes = Array(node.root.description.utf8)
            let offset = node.positionAfterSkippingLeadingTrivia.utf8Offset
            var start = offset
            while start > 0, bytes[start - 1] != UInt8(ascii: "\n") { start -= 1 }
            return bytes[start..<offset].prefix { $0 == UInt8(ascii: " ") }.count
        }
    }

    private final class StatementGrouping: SyntaxVisitor {
        var shape: [String] = []

        init() { super.init(viewMode: .sourceAccurate) }

        override func visit(_ node: CodeBlockItemListSyntax) -> SyntaxVisitorContinueKind {
            shape.append("statements:\(node.count)")
            return .visitChildren
        }

        override func visit(_ node: MemberBlockItemListSyntax) -> SyntaxVisitorContinueKind {
            shape.append("members:\(node.count)")
            return .visitChildren
        }

        override func visit(_ node: ReturnStmtSyntax) -> SyntaxVisitorContinueKind {
            shape.append("return:\(node.expression != nil)")
            return .visitChildren
        }

        override func visit(_ node: BreakStmtSyntax) -> SyntaxVisitorContinueKind {
            shape.append("break:\(node.label?.text ?? "")")
            return .visitChildren
        }

        override func visit(_ node: ContinueStmtSyntax) -> SyntaxVisitorContinueKind {
            shape.append("continue:\(node.label?.text ?? "")")
            return .visitChildren
        }
    }

    // MARK: Fixing

    private final class Inserter: SyntaxRewriter {
        let ids: Set<SyntaxIdentifier>

        init(ids: Set<SyntaxIdentifier>) {
            self.ids = ids
            super.init(viewMode: .sourceAccurate)
        }

        override func visit(_ node: MemberBlockItemSyntax) -> MemberBlockItemSyntax {
            var result = super.visit(node)
            guard ids.contains(node.id), let token = result.firstToken(viewMode: .sourceAccurate),
                  let index = BlankLines.insertionPoint(in: Array(token.leadingTrivia)) else { return result }

            var pieces = Array(token.leadingTrivia)
            pieces[index] = pieces[index].oneNewlineMore
            result.leadingTrivia = Trivia(pieces: pieces)
            return result
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

    var isNewline: Bool { newlineCount > 0 }

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
    var needsControlFlowSemicolon: Bool {
        if let statement = item.as(ReturnStmtSyntax.self) { return statement.expression == nil }
        if let statement = item.as(BreakStmtSyntax.self) { return statement.label == nil }
        if let statement = item.as(ContinueStmtSyntax.self) { return statement.label == nil }
        return false
    }
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
