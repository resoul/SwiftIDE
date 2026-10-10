import Foundation
import IDEDomain

/// A problem as it is drawn: where, how bad, what it says, and how far its place can be trusted.
public struct DiagnosticMark: Equatable, Sendable {
    public enum Freshness: Equatable, Sendable {
        /// The server named the version it analysed and the text has not changed since.
        case verified
        /// The server named no version (SourceKit-LSP of Xcode 27 does not): the report may have been
        /// made for text older than the one on screen, so its place is shown without a promise.
        case unverified
        /// The text has changed since the report arrived: the place is the old one moved along with
        /// the edits, an approximation.
        case stale
    }

    public let range: UTF16TextRange
    public let severity: DocumentDiagnostic.Severity
    public let message: String
    public let freshness: Freshness

    public var isStale: Bool { freshness == .stale }

    public init(range: UTF16TextRange, severity: DocumentDiagnostic.Severity, message: String, freshness: Freshness) {
        self.range = range
        self.severity = severity
        self.message = message
        self.freshness = freshness
    }
}

@MainActor
public protocol DiagnosticsPresenting: AnyObject {
    /// Shows exactly these marks (and none others).
    func show(_ marks: [DiagnosticMark])
}

/// Keeps what the server said about a document where it belongs while the text changes, and
/// tells the screen.
///
/// A report is for the text as it was; each edit made after it moves the marks along (a mark whose
/// text is edited grows or shrinks with it, and stays until the next report replaces them all). A
/// change the controller cannot follow, such as a jump in versions, takes the marks off rather than
/// leave them in the wrong place.
@MainActor
public final class DiagnosticsController {
    public struct Summary: Equatable, Sendable {
        public var errors = 0
        public var warnings = 0

        public init(errors: Int = 0, warnings: Int = 0) {
            self.errors = errors
            self.warnings = warnings
        }

        public var isEmpty: Bool { errors == 0 && warnings == 0 }

        /// "2 errors, 1 warning", or nil when there is nothing to say.
        public var text: String? {
            guard !isEmpty else { return nil }

            var parts: [String] = []
            if errors > 0 { parts.append(errors == 1 ? "1 error" : "\(errors) errors") }
            if warnings > 0 { parts.append(warnings == 1 ? "1 warning" : "\(warnings) warnings") }

            return parts.joined(separator: ", ")
        }
    }

    public private(set) var marks: [DiagnosticMark] = []
    public private(set) var summary = Summary()
    /// Called after the marks changed.
    public var onChange: (@MainActor () -> Void)?

    private let session: DocumentSession
    private let provider: any DiagnosticsProviding
    private weak var presenter: (any DiagnosticsPresenting)?
    private let lineIndex: DocumentLineIndex?
    private let source: (any TextSource)?
    private var items: [DocumentDiagnostic] = []
    private var reportVersion: UInt64 = 0
    private var reportIsVerified = false
    /// The document version `items` are placed for; nil when they are not placed for any.
    private var trackedVersion: UInt64?
    private var changeSubscription: UUID?
    private var providerSubscription: UUID?

    /// With `lineIndex` and `source`, a problem that has no extent (a compiler reports "missing
    /// argument" at the closing parenthesis, between characters) is shown over the word at that place
    /// or, where there is none, over the line; without them marks are exactly as reported.
    public init(
        session: DocumentSession,
        provider: any DiagnosticsProviding,
        presenter: any DiagnosticsPresenting,
        lineIndex: DocumentLineIndex? = nil,
        source: (any TextSource)? = nil
    ) {
        self.session = session
        self.provider = provider
        self.presenter = presenter
        self.lineIndex = lineIndex
        self.source = source
        changeSubscription = session.subscribeToChanges { [weak self] change in self?.followed(change) }
        providerSubscription = provider.subscribeToDiagnostics(for: session) { [weak self] in self?.reported() }
        reported()
    }

    isolated deinit {
        if let changeSubscription { session.unsubscribeFromChanges(changeSubscription) }
        if let providerSubscription { provider.unsubscribeFromDiagnostics(providerSubscription) }
    }

    /// The problems at a place in the text, worst first: what a tooltip there says.
    public func marks(at offset: Int) -> [DiagnosticMark] {
        marks
            .filter { $0.range.location <= offset && offset < max($0.range.location + $0.range.length, $0.range.location + 1) }
            .sorted { $0.severity < $1.severity }
    }

    /// The problems of a line, worst first: what a tooltip on the margin says. `lineOf` gives the
    /// zero-based line of an offset.
    public func marks(onLine line: Int, lineOf: (Int) -> Int) -> [DiagnosticMark] {
        marks.filter { lineOf($0.range.location) == line }.sorted { $0.severity < $1.severity }
    }

    /// The worst severity on each line, for the margin.
    public func severitiesByLine(lineOf: (Int) -> Int) -> [Int: DocumentDiagnostic.Severity] {
        var result: [Int: DocumentDiagnostic.Severity] = [:]
        for mark in marks {
            let line = lineOf(mark.range.location)
            if let known = result[line], known <= mark.severity { continue }

            result[line] = mark.severity
        }

        return result
    }

    // MARK: Following

    private func reported() {
        guard let report = provider.diagnostics(for: session) else {
            items = []
            trackedVersion = nil

            return publish()
        }

        items = report.items
        reportVersion = report.version
        reportIsVerified = report.isVerified
        trackedVersion = report.version
        // A report for the version the document has now is placed as it is; one for an older version
        // would have been refused by the provider.
        if report.version != session.version { trackedVersion = nil; items = [] }

        publish()
    }

    private func shown(_ range: UTF16TextRange) -> UTF16TextRange {
        guard let lineIndex, let source else { return range }

        return DiagnosticPlacement.widened(range, in: lineIndex.current) { source.substring(in: $0) }
    }

    private func followed(_ change: DocumentChangeSet) {
        guard !items.isEmpty || trackedVersion != nil else { return }

        guard change.oldVersion == trackedVersion else {
            items = []
            trackedVersion = nil

            return publish()
        }

        items = items.map { item in
            DocumentDiagnostic(
                range: DiagnosticPlacement.range(item.range, through: change.edits),
                severity: item.severity,
                message: item.message,
                source: item.source
            )
        }
        trackedVersion = change.newVersion
        publish()
    }

    private func publish() {
        // Edited since: stale, whatever the report was. Not edited: as sure as the report was.
        let freshness: DiagnosticMark.Freshness = trackedVersion != reportVersion ? .stale : (reportIsVerified ? .verified : .unverified)
        marks = items.map { DiagnosticMark(range: shown($0.range), severity: $0.severity, message: $0.message, freshness: freshness) }
        summary = Summary(
            errors: items.filter { $0.severity == .error }.count,
            warnings: items.filter { $0.severity == .warning }.count
        )
        presenter?.show(marks)
        onChange?()
    }
}

/// Where a range of text goes when edits are made in it.
public enum DiagnosticPlacement {
    /// A range with no extent shown over something a person can see: the word the place is in or
    /// ends, else the line's text without its indentation and trailing blanks. Left as it is where
    /// there is nothing to show (an empty line), and for every range that has an extent.
    @MainActor
    public static func widened(_ range: UTF16TextRange, in index: LineIndex, text: (UTF16TextRange) -> String) -> UTF16TextRange {
        let length = index.utf16Length
        guard range.length == 0, length > 0, range.location >= 0, range.location <= length else { return range }

        if let word = WordRange.around(range.location, length: length, text: text) { return word }

        if range.location > 0, let word = WordRange.around(range.location - 1, length: length, text: text) { return word }

        let line = index.line(containing: range.location)
        let start = index.startOffset(ofLine: line)
        let content = min(index.lineExtent(line).content, 1_000)
        let units = Array(text(UTF16TextRange(location: start, length: content)).utf16)
        func isBlank(_ unit: UInt16) -> Bool { unit == 0x20 || unit == 0x09 }
        var first = 0, last = units.count
        while first < last, isBlank(units[first]) { first += 1 }
        while last > first, isBlank(units[last - 1]) { last -= 1 }

        return first < last ? UTF16TextRange(location: start + first, length: last - first) : range
    }

    /// `edits` are those of one change set: positions in the text before it, in descending order.
    /// A position inside an edited range goes to the start of what replaced it when it is the start
    /// of the range, and to the end of it when it is the end, so a mark over edited text grows or
    /// shrinks with it.
    public static func range(_ range: UTF16TextRange, through edits: [DocumentEdit]) -> UTF16TextRange {
        let start = position(range.location, through: edits, isStart: true)
        let end = max(start, position(range.location + range.length, through: edits, isStart: false))

        return UTF16TextRange(location: start, length: end - start)
    }

    private static func position(_ original: Int, through edits: [DocumentEdit], isStart: Bool) -> Int {
        var shift = 0
        for edit in edits {
            let from = edit.range.location, to = from + edit.range.length
            let added = edit.replacement.utf16.count - edit.range.length
            if to < original {
                shift += added                                    // wholly before the position
            } else if edit.range.length == 0 && from == original {
                if isStart { shift += added }                     // typed in front of a mark: the mark moves on
                // typed at the end of a mark: it is not part of it
            } else if to == original {
                shift += added                                    // the replaced text ends at the position
            } else if from < original {
                // Inside the replaced text: the start goes to where the new text begins, the end to where it ends.
                shift += (isStart ? 0 : edit.replacement.utf16.count) - (original - from)
            }
        }

        return original + shift
    }
}
