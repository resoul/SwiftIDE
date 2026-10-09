/// Where colouring stops being worth its cost (ADR-014). Both limits come from measurements
/// (docs/benchmarks/TK-007c-results.md) and are provisional until the matrix is repeated on other
/// machines.
public struct SyntaxPolicy: Sendable, Equatable {
    /// Documents longer than this (UTF-16 units) are not coloured at all.
    public var maximumDocumentLength: Int
    /// A line (one layout fragment) longer than this is drawn plain, whatever the document size.
    public var maximumFragmentLength: Int
    /// A line with more coloured runs than this is drawn plain. Editing a line costs TextKit time
    /// in proportion to its runs, not to its length (docs/benchmarks/TK-007c-wide-lines.json).
    public var maximumSpansPerFragment: Int

    public init(
        maximumDocumentLength: Int = 5 * 1_048_576, maximumFragmentLength: Int = 1_000,
        maximumSpansPerFragment: Int = 50
    ) {
        self.maximumDocumentLength = maximumDocumentLength
        self.maximumFragmentLength = maximumFragmentLength
        self.maximumSpansPerFragment = maximumSpansPerFragment
    }

    public static let standard = SyntaxPolicy()

    public func allowsColouring(documentLength: Int) -> Bool {
        documentLength <= maximumDocumentLength
    }
}
