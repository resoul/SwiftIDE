import Foundation
import IDEApplication
import IDEDomain

/// A highlighter for a language that is coloured by scanning its text, not by a grammar. It keeps its
/// own copy of the text like every highlighter, and runs the scan over the whole document once per
/// version (the colour of a line can depend on lines above it); a request for a window is then
/// answered from that.
public class ScannedHighlighter: SyntaxHighlighter, @unchecked Sendable {
    /// Documents larger than this (UTF-16 units) get no colours.
    public static let sizeLimit = 2_000_000

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

    private let newest = NewestRequest()
    private let messages: AsyncStream<Message>.Continuation
    private let worker: Task<Void, Never>

    /// - Parameter colours: a kind (`HighlightKind.rawValue`, 0 for none) for every UTF-16 unit.
    public init(colours: @escaping @Sendable ([UInt16]) -> [UInt8]) {
        let newest = newest
        let engine = Engine(colours: colours, isStale: { newest.isOlderThanNewest($0) })
        let (stream, continuation) = AsyncStream<Message>.makeStream(bufferingPolicy: .unbounded)
        messages = continuation
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

    public func connect(onResult: @escaping @Sendable (HighlightResult) -> Void) { messages.yield(.connect(onResult)) }

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

    private actor Engine {
        private var text = ChunkedText()
        private var version: UInt64 = 0
        private var lost = false
        private var cached: (version: UInt64, kinds: [UInt8])?
        private var handler: (@Sendable (HighlightResult) -> Void)?
        private let isStale: @Sendable (UInt64) -> Bool
        private let colours: @Sendable ([UInt16]) -> [UInt8]

        init(colours: @escaping @Sendable ([UInt16]) -> [UInt8], isStale: @escaping @Sendable (UInt64) -> Bool) {
            self.colours = colours
            self.isStale = isStale
        }

        func setHandler(_ handler: @escaping @Sendable (HighlightResult) -> Void) { self.handler = handler }

        func release() {
            text = ChunkedText()
            cached = nil
            handler = nil
            lost = true
        }

        func reset(text chunks: [[UInt16]], version: UInt64) {
            text = ChunkedText(chunks: chunks)
            cached = nil
            lost = false
            self.version = version
        }

        func apply(_ changes: DocumentChangeSet) {
            guard !lost else { return }

            for edit in changes.edits {
                let start = edit.range.location
                let oldEnd = start + edit.range.length
                guard oldEnd <= text.length, text.replace(start..<oldEnd, with: Array(edit.replacement.utf16)) else {
                    lost = true

                    return
                }
            }
            version = changes.newVersion
            cached = nil
        }

        func highlights(in window: Range<Int>, version requested: UInt64) {
            guard !lost, requested == version, !isStale(requested), let handler else { return }

            let kinds: [UInt8]
            if let cached, cached.version == version {
                kinds = cached.kinds
            } else if text.length <= ScannedHighlighter.sizeLimit {
                kinds = colours(Array(text.substring(0..<text.length).utf16))
                cached = (version, kinds)
            } else {
                kinds = []
            }

            let lower = min(max(0, window.lowerBound), text.length)
            let clamped = lower..<min(text.length, max(lower, window.upperBound))
            var spans: [HighlightSpan] = []
            var index = clamped.lowerBound
            while index < clamped.upperBound, index < kinds.count {
                guard kinds[index] != 0, let kind = HighlightKind(rawValue: kinds[index]) else {
                    index += 1
                    continue
                }

                var end = index + 1
                while end < clamped.upperBound, end < kinds.count, kinds[end] == kinds[index] { end += 1 }
                spans.append(HighlightSpan(location: index, length: end - index, kind: kind))
                index = end
            }
            handler(HighlightResult(version: version, window: clamped, spans: spans, documentLength: text.length))
        }
    }
}

/// Colours Markdown.
public final class MarkdownHighlighter: ScannedHighlighter {
    public init() { super.init(colours: MarkdownColours.kinds(for:)) }
}

/// Which highlighter a language gets.
public enum SyntaxHighlighters {
    /// The scanners, by language: each takes the text and gives a kind for every unit.
    private static let scanners: [DocumentLanguage: @Sendable ([UInt16]) -> [UInt8]] = [
        .json: JSONColours.kinds(for:),
        .xml: XMLColours.kinds(for:),
        .toml: TOMLColours.kinds(for:),
        .metal: MetalColours.kinds(for:),
        .config: ConfigColours.kinds(for:)
    ]

    /// The languages that have colours: those with a grammar, those that are scanned, and Markdown.
    public static var supportedLanguages: Set<DocumentLanguage> {
        TreeSitterHighlighter.supportedLanguages.union(scanners.keys).union([.markdown])
    }

    public static func make(for language: DocumentLanguage) -> (any SyntaxHighlighter)? {
        if language == .markdown { return MarkdownHighlighter() }

        if let scanner = scanners[language] { return ScannedHighlighter(colours: scanner) }

        return try? TreeSitterHighlighter(language: language)
    }
}
