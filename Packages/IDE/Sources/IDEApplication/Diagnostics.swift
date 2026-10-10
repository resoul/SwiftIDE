import Foundation
import IDEDomain

/// A problem the language server reported, placed in the text.
public struct DocumentDiagnostic: Equatable, Sendable {
    public enum Severity: Int, Comparable, Sendable {
        case error = 1, warning, information, hint

        /// Errors first.
        public static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public let range: UTF16TextRange
    public let severity: Severity
    public let message: String
    public let source: String?

    public init(range: UTF16TextRange, severity: Severity, message: String, source: String? = nil) {
        self.range = range
        self.severity = severity
        self.message = message
        self.source = source
    }
}

/// What the server said about a document, in the text as it was at `version`.
public struct DocumentDiagnostics: Equatable, Sendable {
    public let items: [DocumentDiagnostic]
    /// The document version the ranges are for.
    public let version: UInt64
    /// The server named the version it analysed. SourceKit-LSP of Xcode 27 does not, so its
    /// reports are not verified: they are as fresh as the last edit before they arrived.
    public let isVerified: Bool

    public init(items: [DocumentDiagnostic], version: UInt64, isVerified: Bool) {
        self.items = items
        self.version = version
        self.isVerified = isVerified
    }
}

/// Where a document's diagnostics come from. The observer is called when a new report arrives and
/// when the document is no longer with any server (then `diagnostics` is nil).
@MainActor
public protocol DiagnosticsProviding: AnyObject {
    func diagnostics(for session: DocumentSession) -> DocumentDiagnostics?

    @discardableResult
    func subscribeToDiagnostics(for session: DocumentSession, _ observer: @escaping @MainActor () -> Void) -> UUID

    func unsubscribeFromDiagnostics(_ id: UUID)
}
