import Foundation
import IDEApplication
import IDEDomain
import SwiftTreeSitter
import TreeSitterSwift

/// What the highlighter's thread has done so far: for measuring, not for the editor.
public struct HighlighterStatistics: Sendable, Equatable {
    /// Requests that were answered with colours.
    public var answered = 0
    /// Requests dropped because the text had moved on, or a newer request was queued.
    public var skipped = 0
    public var parses = 0
    public var parseMilliseconds = 0.0
    /// Looking for a block comment that is never closed: reads the whole text after every parse.
    public var commentSearchMilliseconds = 0.0
    public var spanMilliseconds = 0.0
}

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
        case stop
    }

    /// The newest version colours were asked for. A request for an older one that is still in the
    /// queue is not worth a parse: the editor discards its answer, the document moved on.
    private final class NewestRequest: @unchecked Sendable {
        private let lock = NSLock()
        private var version: UInt64 = 0
        func note(_ requested: UInt64) { lock.withLock { version = max(version, requested) } }
        func isOlderThanNewest(_ requested: UInt64) -> Bool { lock.withLock { requested < version } }
    }

    private let engine: Engine
    private let newest = NewestRequest()
    private let messages: AsyncStream<Message>.Continuation
    private let worker: Task<Void, Never>

    public init() throws {
        guard let url = Bundle.module.url(forResource: "swift-highlights", withExtension: "scm", subdirectory: "Resources") else {
            throw SyntaxInfrastructureError.missingQuery
        }
        let query = try Query(language: Language(tree_sitter_swift()), data: Data(contentsOf: url))
        let newest = newest
        let engine = Engine(query: query, isStale: { newest.isOlderThanNewest($0) })
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
                case .stop: await engine.release()
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
    public func requestHighlights(in window: Range<Int>, version: UInt64) {
        newest.note(version)
        messages.yield(.request(window, version))
    }
    /// Drops the tree and the copy of the text at once, whoever still holds this object.
    public func stop() {
        messages.yield(.stop)
        messages.finish()
    }

    public func statistics() async -> HighlighterStatistics { await engine.statistics }

    /// What the engine holds, for tests.
    func retainedState() async -> (units: Int, hasTree: Bool) { await engine.retained() }

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
        private(set) var statistics = HighlighterStatistics()

        private let isStale: @Sendable (UInt64) -> Bool

        init(query: Query, isStale: @escaping @Sendable (UInt64) -> Bool) {
            self.query = query
            self.isStale = isStale
            try? parser.setLanguage(Language(tree_sitter_swift()))
        }

        /// Everything that grows with the document: the stop of a highlighter gives it back.
        func release() {
            tree = nil
            text = ChunkedText()
            lines = LineIndex()
            handler = nil
            unterminatedComment = nil
            lost = true
        }

        func retained() -> (units: Int, hasTree: Bool) { (text.length, tree != nil) }

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
            guard !lost, requested == version, !isStale(requested), let handler else { statistics.skipped += 1; return }
            if needsParse || tree == nil {
                let source = text
                let began = ContinuousClock.now
                tree = parser.parse(tree: tree, readBlock: { byteOffset, _ in source.bytes(fromUnit: byteOffset / 2) }) ?? tree
                statistics.parseMilliseconds += Self.milliseconds(since: began)
                statistics.parses += 1
                needsParse = false
                let searchBegan = ContinuousClock.now
                unterminatedComment = tree.flatMap { findUnterminatedComment(in: $0) }
                statistics.commentSearchMilliseconds += Self.milliseconds(since: searchBegan)
            }
            guard let tree else { return }
            // A window asked for before an edit can reach past the end of the text now.
            let lower = min(max(0, window.lowerBound), text.length)
            let clamped = lower..<min(text.length, max(lower, window.upperBound))
            let spansBegan = ContinuousClock.now
            let found = spans(in: clamped, tree: tree)
            statistics.spanMilliseconds += Self.milliseconds(since: spansBegan)
            statistics.answered += 1
            handler(HighlightResult(version: version, window: clamped, spans: found, documentLength: text.length))
        }

        private static func milliseconds(since start: ContinuousClock.Instant) -> Double {
            let d = start.duration(to: .now)
            return Double(d.components.seconds) * 1_000 + Double(d.components.attoseconds) / 1e15
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
