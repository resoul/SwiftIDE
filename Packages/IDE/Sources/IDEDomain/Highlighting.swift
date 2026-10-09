import Foundation

/// What a piece of source text is, for colouring. Text with no kind is drawn plain.
public enum HighlightKind: UInt8, Sendable, CaseIterable {
    case keyword = 1, string, escape, number, comment, documentation
    case type, function, property, parameter, constant, attribute, `operator`, label, builtin
}

/// A coloured run of UTF-16 text.
public struct HighlightSpan: Equatable, Sendable {
    public var location: Int
    public var length: Int
    public var kind: HighlightKind

    public init(location: Int, length: Int, kind: HighlightKind) {
        self.location = location
        self.length = length
        self.kind = kind
    }

    public var end: Int { location + length }
}

/// Highlights computed for one version of a document over one window of it.
public struct HighlightResult: Sendable {
    public let version: UInt64
    /// The part of the document these spans describe; text in it without a span is plain.
    public let window: Range<Int>
    /// Sorted, not overlapping, all inside `window`.
    public let spans: [HighlightSpan]
    /// Length of the text the highlighter was working on, so a mismatch with the document shows.
    public let documentLength: Int

    public init(version: UInt64, window: Range<Int>, spans: [HighlightSpan], documentLength: Int) {
        self.version = version
        self.window = window
        self.spans = spans
        self.documentLength = documentLength
    }
}
