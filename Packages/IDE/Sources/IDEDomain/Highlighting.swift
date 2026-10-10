import Foundation

public enum HighlightKind: UInt8, Sendable, CaseIterable {
    case keyword = 1, string, escape, number, comment, documentation
    case type, function, property, parameter, constant, attribute, `operator`, label, builtin
}

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

public struct HighlightResult: Sendable {
    public let version: UInt64
    public let window: Range<Int>
    public let spans: [HighlightSpan]
    public let documentLength: Int

    public init(version: UInt64, window: Range<Int>, spans: [HighlightSpan], documentLength: Int) {
        self.version = version
        self.window = window
        self.spans = spans
        self.documentLength = documentLength
    }
}
