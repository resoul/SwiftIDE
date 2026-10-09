import Foundation
import IDEApplication
import IDEDomain
import SwiftTreeSitter
import TreeSitterSwift

public enum SyntaxInfrastructureError: Error {
    case missingQuery
}

/// Swift syntax colours from tree-sitter, computed off the main thread.
///
/// It keeps its own copy of the text (chunked, so an edit costs the edit) and its own line index,
/// feeds each edit to the previous syntax tree, and parses again only when colours are asked for.
/// Nothing here is shared with the editor: edits and requests arrive in order through one queue.
public final class TreeSitterHighlighter: SyntaxHighlighter {
    private enum Message: Sendable {
        case connect(@Sendable (HighlightResult) -> Void)
        case reset([[UInt16]], UInt64)
        case edit(DocumentChangeSet)
        case request(Range<Int>, UInt64)
    }

    private let engine: Engine
    private let messages: AsyncStream<Message>.Continuation
    private let worker: Task<Void, Never>

    public init() throws {
        guard let url = Bundle.module.url(forResource: "swift-highlights", withExtension: "scm", subdirectory: "Resources") else {
            throw SyntaxInfrastructureError.missingQuery
        }
        let query = try Query(language: Language(tree_sitter_swift()), data: Data(contentsOf: url))
        let engine = Engine(query: query)
        let (stream, continuation) = AsyncStream<Message>.makeStream(bufferingPolicy: .unbounded)
        self.engine = engine
        self.messages = continuation
        worker = Task.detached(priority: .utility) {
            for await message in stream {
                switch message {
                case .connect(let handler): await engine.setHandler(handler)
                case .reset(let text, let version): await engine.reset(text: text, version: version)
                case .edit(let changes): await engine.apply(changes)
                case .request(let window, let version): await engine.highlights(in: window, version: version)
                }
            }
        }
    }

    deinit { messages.finish() }

    /// Goes through the same queue as everything else: a request sent right after `connect` must
    /// find the handler in place, not race a separate task for it.
    public func connect(onResult: @escaping @Sendable (HighlightResult) -> Void) {
        messages.yield(.connect(onResult))
    }

    public func reset(text: [[UInt16]], version: UInt64) { messages.yield(.reset(text, version)) }
    public func edit(_ changes: DocumentChangeSet) { messages.yield(.edit(changes)) }
    public func requestHighlights(in window: Range<Int>, version: UInt64) { messages.yield(.request(window, version)) }
    public func stop() { messages.finish() }

    // MARK: The work

    private actor Engine {
        private let query: Query
        private let parser = Parser()
        private var tree: MutableTree?
        private var text = ChunkedText()
        private var lines = LineIndex()
        private var version: UInt64 = 0
        /// Edits were applied to the tree since it was last parsed.
        private var needsParse = true
        /// Where a block comment that is never closed begins, if there is one. The grammar only
        /// knows a closed comment; Swift reads an unclosed one to the end of the text.
        private var unterminatedComment: Int?
        /// An edit that did not fit the copy of the text: nothing is trusted until a reset.
        private var lost = false
        private var handler: (@Sendable (HighlightResult) -> Void)?

        init(query: Query) {
            self.query = query
            try? parser.setLanguage(Language(tree_sitter_swift()))
        }

        func setHandler(_ handler: @escaping @Sendable (HighlightResult) -> Void) {
            self.handler = handler
        }

        func reset(text chunks: [[UInt16]], version: UInt64) {
            text = ChunkedText(chunks: chunks)
            lines = LineIndex(utf16Chunks: chunks)
            tree = nil
            needsParse = true
            lost = false
            self.version = version
        }

        func apply(_ changes: DocumentChangeSet) {
            guard !lost else { return }
            for edit in changes.edits {   // last position first: each range is valid when its turn comes
                let start = edit.range.location
                let oldEnd = start + edit.range.length
                let units = Array(edit.replacement.utf16)
                guard oldEnd <= lines.utf16Length else { lost = true; return }
                let startPoint = point(at: start), oldEndPoint = point(at: oldEnd)
                guard lines.replace(edit.range, with: edit.replacement),
                      text.replace(start..<oldEnd, with: units) else { lost = true; return }
                let newEnd = start + units.count
                tree?.edit(InputEdit(
                    startByte: start * 2, oldEndByte: oldEnd * 2, newEndByte: newEnd * 2,
                    startPoint: startPoint, oldEndPoint: oldEndPoint, newEndPoint: point(at: newEnd)
                ))
            }
            version = changes.newVersion
            needsParse = true
        }

        func highlights(in window: Range<Int>, version requested: UInt64) {
            guard !lost, requested == version, let handler else { return }
            if needsParse || tree == nil {
                let source = text
                tree = parser.parse(tree: tree, readBlock: { byteOffset, _ in source.bytes(fromUnit: byteOffset / 2) }) ?? tree
                needsParse = false
                unterminatedComment = tree.flatMap { findUnterminatedComment(in: $0) }
            }
            guard let tree else { return }
            // A window asked for before an edit can reach past the end of the text now.
            let lower = min(max(0, window.lowerBound), text.length)
            let clamped = lower..<min(text.length, max(lower, window.upperBound))
            handler(HighlightResult(
                version: version, window: clamped,
                spans: spans(in: clamped, tree: tree), documentLength: text.length
            ))
        }

        /// The first `/*` that the syntax tree does not take for the start of a comment or part of a
        /// string or a line comment: it was read as an operator, which only happens when no `*/`
        /// closes it. Everything after it is comment, whatever the tree makes of it.
        private func findUnterminatedComment(in tree: MutableTree) -> Int? {
            guard let root = tree.rootNode else { return nil }
            var found: Int?
            text.forEachPair(0x2F, 0x2A) { position in
                let bytes = UInt32(position * 2)
                guard let node = root.descendant(in: bytes..<(bytes + 4)) else { return true }
                let type = node.nodeType
                if type == "custom_operator" || (type == "ERROR" && node.byteRange.lowerBound == bytes) {
                    found = position
                    return false
                }
                return true
            }
            return found
        }

        private func point(at offset: Int) -> Point {
            let line = lines.line(containing: offset)
            return Point(row: line, column: (offset - lines.startOffset(ofLine: line)) * 2)
        }

        /// The coloured runs of `window`: every capture of the highlights query painted in pattern
        /// order, so that a later pattern wins where captures overlap.
        private func spans(in window: Range<Int>, tree: MutableTree) -> [HighlightSpan] {
            guard !window.isEmpty else { return [] }
            let cursor = query.execute(in: tree)
            cursor.setRange(NSRange(location: window.lowerBound, length: window.count))
            let source = text
            let context = Predicate.Context(textProvider: { range, _ in
                source.substring(range.location..<(range.location + range.length))
            })
            var painted: [(pattern: Int, order: Int, range: Range<Int>, kind: HighlightKind)] = []
            for match in cursor.resolve(with: context) {
                for capture in match.captures {
                    guard let name = capture.name, let kind = CaptureKinds.kind(for: name) else { continue }
                    let range = capture.range
                    let from = max(window.lowerBound, range.location)
                    let to = min(window.upperBound, range.location + range.length)
                    guard from < to else { continue }
                    painted.append((capture.patternIndex, painted.count, from..<to, kind))
                }
            }
            painted.sort { ($0.pattern, $0.order) < ($1.pattern, $1.order) }
            var kinds = [UInt8](repeating: 0, count: window.count)
            for item in painted {
                for index in (item.range.lowerBound - window.lowerBound)..<(item.range.upperBound - window.lowerBound) {
                    kinds[index] = item.kind.rawValue
                }
            }
            if let opener = unterminatedComment, opener < window.upperBound {
                for index in (max(opener, window.lowerBound) - window.lowerBound)..<kinds.count {
                    kinds[index] = HighlightKind.comment.rawValue
                }
            }
            var result: [HighlightSpan] = []
            var index = 0
            while index < kinds.count {
                guard kinds[index] != 0, let kind = HighlightKind(rawValue: kinds[index]) else { index += 1; continue }
                var end = index + 1
                while end < kinds.count, kinds[end] == kinds[index] { end += 1 }
                result.append(HighlightSpan(location: window.lowerBound + index, length: end - index, kind: kind))
                index = end
            }
            return result
        }
    }
}
