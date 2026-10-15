import Foundation

/// Service-facing failures without a dependency on HTTP/Foundation transport error types.
public struct GitHostingFailure: Error, Sendable, Equatable, LocalizedError {
    public enum Kind: Sendable, Equatable {
        case connection, timedOut, unauthorized, forbidden, notFound, conflict, rateLimited
        case serviceUnavailable, invalidResponse, responseTooLarge, redirectRejected, unexpectedStatus
    }

    public let kind: Kind
    public let statusCode: Int?
    public let retryAfter: TimeInterval?
    public let publicationMayHaveSucceeded: Bool

    public init(
        kind: Kind,
        statusCode: Int? = nil,
        retryAfter: TimeInterval? = nil,
        publicationMayHaveSucceeded: Bool = false
    ) {
        self.kind = kind
        self.statusCode = statusCode
        self.retryAfter = retryAfter
        self.publicationMayHaveSucceeded = publicationMayHaveSucceeded
    }

    public var errorDescription: String? {
        let message: String
        switch kind {
        case .connection: message = "Hosting connection failed."
        case .timedOut: message = "Hosting request timed out."
        case .unauthorized: message = "Reconnect the hosting account."
        case .forbidden: message = "Check hosting token permissions, SSO and rate limits."
        case .notFound: message = "Hosting repository/branch is unavailable or inaccessible."
        case .conflict: message = "Hosting validation failed or a request already exists. Refresh before retrying."
        case .rateLimited: message = "Hosting rate limit reached. Wait before refreshing."
        case .serviceUnavailable: message = "Hosting service is temporarily unavailable."
        case .invalidResponse: message = "Malformed or unsupported hosting response."
        case .responseTooLarge: message = "Hosting response exceeds the 2 MB limit."
        case .redirectRejected: message = "Hosting response redirected to an unexpected address."
        case .unexpectedStatus: message = "Hosting returned an unsupported HTTP status."
        }
        let prefix = statusCode.map { "HTTP \($0). " } ?? ""
        let suffix = publicationMayHaveSucceeded
            ? " A submitted PR/MR may already exist; refresh before retrying."
            : ""

        return prefix + message + suffix
    }
}
