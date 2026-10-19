import Foundation
import IDEApplication
import IDEDomain
import SwiftTreeSitter
import TreeSitterC
import TreeSitterCPP
import TreeSitterObjc
import TreeSitterSwift

public struct HighlighterStatistics: Sendable, Equatable {
    public var answered = 0
    public var skipped = 0
    public var parses = 0
    public var parseMilliseconds = 0.0
    public var commentSearchMilliseconds = 0.0
    public var spanMilliseconds = 0.0
}

public enum SyntaxInfrastructureError: Error {
    case missingQuery
    /// No grammar for this language (plain text, or one not yet supported).
    case unsupportedLanguage(DocumentLanguage)
}

/// What the highlighter needs to know about a language: its grammar, its queries, and how a block
/// comment that is never closed shows up in the syntax tree.
struct Grammar: Sendable {
    /// Node types in which the two characters `/*` do not open a comment: they are inside one
    /// (a comment, a string, an include path) already.
    enum UnterminatedComment: Sendable {
        /// The Swift grammar reads an unclosed `/*` as an operator or an error.
        case swiftOperator
        /// The C-family grammars: a `/*` that is not inside a comment or a literal.
        case outsideOf(Set<String>)
    }

    let language: Language
    let queryResource: String
    let unterminatedComment: UnterminatedComment

    static func make(for language: DocumentLanguage) -> Grammar? {
        let literals: Set<String> = [
            "comment",
            "string_literal",
            "string_content",
            "char_literal",
            "character",
            "raw_string_literal",
            "raw_string_content",
            "system_lib_string",
            "preproc_arg",
            "concatenated_string",
        ]
        switch language {
        case .swift:
            return Grammar(
                language: Language(tree_sitter_swift()),
                queryResource: "swift-highlights",
                unterminatedComment: .swiftOperator
            )
        case .c:
            return Grammar(
                language: Language(tree_sitter_c()),
                queryResource: "c-highlights",
                unterminatedComment: .outsideOf(literals)
            )
        case .cpp:
            return Grammar(
                language: Language(tree_sitter_cpp()),
                queryResource: "cpp-highlights",
                unterminatedComment: .outsideOf(literals)
            )
        case .objectiveC:
            return Grammar(
                language: Language(tree_sitter_objc()),
                queryResource: "objc-highlights",
                unterminatedComment: .outsideOf(literals)
            )
        case .objectiveCPP, .plainText:
            return nil
        }
    }

    /// The grammars a document is read with. Objective-C++ has none of its own: it is read with the
    /// C++ and the Objective-C grammars at once, and `LayerChoice` takes each region from the one
    /// that reads it with fewer errors.
    static func layers(for language: DocumentLanguage) -> [Grammar]? {
        switch language {
        case .objectiveCPP:
            [.cpp, .objectiveC].compactMap { make(for: $0) }
        default:
            make(for: language).map { [$0] }
        }
    }
}

/// One grammar with its compiled query.
struct Layer: @unchecked Sendable {
    let grammar: Grammar
    let query: Query
}

public final class TreeSitterHighlighter: SyntaxHighlighter {
    private enum Message: Sendable {
        case connect(@Sendable (HighlightResult) -> Void)
        case reset([[UInt16]], UInt64)
        case edit(DocumentChangeSet)
        case request(Range<Int>, UInt64)
        case stop
    }

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

    /// The languages there are colours for. Objective-C++ is approximate: no grammar reads the mixture
    /// without errors, so two grammars are combined region by region (ADR-054).
    public static let supportedLanguages: Set<DocumentLanguage> = [.swift, .c, .cpp, .objectiveC, .objectiveCPP]

    public let language: DocumentLanguage

    public init(language: DocumentLanguage = .swift) throws {
        guard let grammars = Grammar.layers(for: language), !grammars.isEmpty else {
            throw SyntaxInfrastructureError.unsupportedLanguage(language)
        }

        var layers: [Layer] = []
        for grammar in grammars {
            guard let url = Bundle.module.url(
                forResource: grammar.queryResource,
                withExtension: "scm",
                subdirectory: "Resources"
            ) else {
                throw SyntaxInfrastructureError.missingQuery
            }

            layers.append(Layer(
                grammar: grammar,
                query: try Query(language: grammar.language, data: Data(contentsOf: url))
            ))
        }

        self.language = language
        let newest = newest
        let engine = Engine(layers: layers, isStale: { newest.isOlderThanNewest($0) })
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

    public func connect(onResult: @escaping @Sendable (HighlightResult) -> Void) {
        messages.yield(.connect(onResult))
    }

    public func reset(text: [[UInt16]], version: UInt64) { messages.yield(.reset(text, version)) }

    public func edit(_ changes: DocumentChangeSet) { messages.yield(.edit(changes)) }

    public func requestHighlights(in window: Range<Int>, version: UInt64) {
        newest.note(version)
        messages.yield(.request(window, version))
    }

    public func stop() {
        messages.yield(.stop)
        messages.finish()
    }

    public func statistics() async -> HighlighterStatistics { await engine.statistics }

    func retainedState() async -> (units: Int, hasTree: Bool) { await engine.retained() }

    // MARK: The work

    private actor Engine {
        private struct Parsed {
            let parser = Parser()
            var tree: MutableTree?
        }

        private let layers: [Layer]
        private var parsed: [Parsed]
        private var choice = LayerChoice()
        private var text = ChunkedText()
        private var lines = LineIndex()
        private var version: UInt64 = 0
        private var needsParse = true
        private var unterminatedComment: Int?
        private var lost = false
        private var handler: (@Sendable (HighlightResult) -> Void)?

        private(set) var statistics = HighlighterStatistics()

        private let isStale: @Sendable (UInt64) -> Bool

        init(layers: [Layer], isStale: @escaping @Sendable (UInt64) -> Bool) {
            self.layers = layers
            self.isStale = isStale
            parsed = layers.map { layer in
                let entry = Parsed()
                try? entry.parser.setLanguage(layer.grammar.language)

                return entry
            }
        }

        func release() {
            for index in parsed.indices { parsed[index].tree = nil }
            choice = LayerChoice()
            text = ChunkedText()
            lines = LineIndex()
            handler = nil
            unterminatedComment = nil
            lost = true
        }

        func retained() -> (units: Int, hasTree: Bool) { (text.length, parsed.contains { $0.tree != nil }) }

        func setHandler(_ handler: @escaping @Sendable (HighlightResult) -> Void) {
            self.handler = handler
        }

        func reset(text chunks: [[UInt16]], version: UInt64) {
            text = ChunkedText(chunks: chunks)
            lines = LineIndex(utf16Chunks: chunks)
            for index in parsed.indices { parsed[index].tree = nil }
            needsParse = true
            lost = false
            self.version = version
        }

        func apply(_ changes: DocumentChangeSet) {
            guard !lost else { return }

            for edit in changes.edits {
                let start = edit.range.location
                let oldEnd = start + edit.range.length
                let units = Array(edit.replacement.utf16)
                guard oldEnd <= lines.utf16Length else {
                    lost = true

                    return
                }

                let startPoint = point(at: start), oldEndPoint = point(at: oldEnd)
                guard lines.replace(edit.range, with: edit.replacement),
                      text.replace(start..<oldEnd, with: units) else {
                    lost = true

                    return
                }

                let newEnd = start + units.count
                let inputEdit = InputEdit(
                    startByte: start * 2,
                    oldEndByte: oldEnd * 2,
                    newEndByte: newEnd * 2,
                    startPoint: startPoint,
                    oldEndPoint: oldEndPoint,
                    newEndPoint: point(at: newEnd)
                )
                for index in parsed.indices { parsed[index].tree?.edit(inputEdit) }
            }
            version = changes.newVersion
            needsParse = true
        }

        func highlights(in window: Range<Int>, version requested: UInt64) {
            guard !lost, requested == version, !isStale(requested), let handler else {
                statistics.skipped += 1

                return
            }

            if needsParse || parsed.contains(where: { $0.tree == nil }) {
                let source = text
                let began = ContinuousClock.now
                for index in parsed.indices {
                    let previous = parsed[index].tree
                    parsed[index].tree = parsed[index].parser.parse(
                        tree: previous,
                        readBlock: { byteOffset, _ in source.bytes(fromUnit: byteOffset / 2) }
                    ) ?? previous
                }
                statistics.parseMilliseconds += Self.milliseconds(since: began)
                statistics.parses += 1
                needsParse = false
                let searchBegan = ContinuousClock.now
                unterminatedComment = parsed.first?.tree.flatMap { findUnterminatedComment(in: $0, layer: layers[0]) }
                statistics.commentSearchMilliseconds += Self.milliseconds(since: searchBegan)
                choice = layers.count > 1
                    ? LayerChoice(trees: parsed.compactMap(\.tree), length: text.length) { [text] in
                        text.unit(at: $0) == 0x40
                    }
                    : LayerChoice()
            }

            guard parsed.allSatisfy({ $0.tree != nil }) else { return }

            let lower = min(max(0, window.lowerBound), text.length)
            let clamped = lower..<min(text.length, max(lower, window.upperBound))
            let spansBegan = ContinuousClock.now
            let found = spans(in: clamped)
            statistics.spanMilliseconds += Self.milliseconds(since: spansBegan)
            statistics.answered += 1
            handler(HighlightResult(version: version, window: clamped, spans: found, documentLength: text.length))
        }

        private static func milliseconds(since start: ContinuousClock.Instant) -> Double {
            let d = start.duration(to: .now)

            return Double(d.components.seconds) * 1_000 + Double(d.components.attoseconds) / 1e15
        }

        private func findUnterminatedComment(in tree: MutableTree, layer: Layer) -> Int? {
            guard let root = tree.rootNode else { return nil }

            var found: Int?
            text.forEachPair(0x2F, 0x2A) { position in
                let bytes = UInt32(position * 2)
                switch layer.grammar.unterminatedComment {
                case .swiftOperator:
                    guard let node = root.descendant(in: bytes..<(bytes + 4)) else { return true }

                    let type = node.nodeType
                    if type == "custom_operator" || (type == "ERROR" && node.byteRange.lowerBound == bytes) {
                        found = position

                        return false
                    }
                case .outsideOf(let containers):
                    // A `/*` that opened a comment is inside a comment node; one in a string or
                    // after `//` is inside that. Anywhere else the comment was never closed.
                    var node = root.descendant(in: bytes..<(bytes + 2))
                    while let current = node {
                        if let type = current.nodeType, containers.contains(type) { return true }
                        node = current.parent
                    }
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

        /// The kind of every unit of the window, as one grammar reads it.
        private func kinds(in window: Range<Int>, layer index: Int) -> [UInt8] {
            var kinds = [UInt8](repeating: 0, count: window.count)
            guard let tree = parsed[index].tree else { return kinds }

            let cursor = layers[index].query.execute(in: tree)
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
            for item in painted {
                for position in (item.range.lowerBound - window.lowerBound)..<(item.range.upperBound - window
                    .lowerBound) {
                    kinds[position] = item.kind.rawValue
                }
            }

            return kinds
        }

        private func spans(in window: Range<Int>) -> [HighlightSpan] {
            guard !window.isEmpty else { return [] }

            var kinds: [UInt8]
            if layers.count == 1 {
                kinds = self.kinds(in: window, layer: 0)
            } else {
                let perLayer = layers.indices.map { self.kinds(in: window, layer: $0) }
                kinds = [UInt8](repeating: 0, count: window.count)
                for region in choice.regions(in: window) {
                    for position in region.range {
                        let at = position - window.lowerBound
                        var kind = perLayer[region.layer][at]
                        if kind == 0, region.isApproximate {
                            kind = perLayer.lazy.map { $0[at] }.first { $0 != 0 } ?? 0
                        }

                        kinds[at] = kind
                    }
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
                guard kinds[index] != 0, let kind = HighlightKind(rawValue: kinds[index]) else {
                    index += 1
                    continue
                }

                var end = index + 1
                while end < kinds.count, kinds[end] == kinds[index] { end += 1 }
                result.append(HighlightSpan(location: window.lowerBound + index, length: end - index, kind: kind))
                index = end
            }

            return result
        }
    }
}
