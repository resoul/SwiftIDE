import Foundation
import OSLog

/// An allowlist of metadata. No request/response object or free-form error text reaches the sink.
public struct HTTPDiagnosticEvent: Sendable {
    public enum Method: String, Sendable {
        case get = "GET", head = "HEAD", post = "POST", put = "PUT", patch = "PATCH", delete = "DELETE"
        case options = "OPTIONS", trace = "TRACE", connect = "CONNECT", other = "OTHER"
    }

    public enum Outcome: String, Sendable { case response, failed, cancelled }

    public let requestID: UUID
    public let method: Method
    public let duration: TimeInterval
    public let statusCode: Int?
    public let receivedBytes: Int
    public let outcome: Outcome
    public let failure: HTTPError?
}

public protocol HTTPDiagnostics: Sendable {
    /// Implementations must be fast and safe to call concurrently; no external telemetry is required.
    func record(_ event: HTTPDiagnosticEvent)
}

public struct NoHTTPDiagnostics: HTTPDiagnostics {
    public init() {}

    public func record(_ event: HTTPDiagnosticEvent) {}
}

/// Local system logging; only fields from HTTPDiagnosticEvent are logged.
public struct OSLogHTTPDiagnostics: HTTPDiagnostics {
    private let logger = Logger(subsystem: "SwiftIDE", category: "http")

    public init() {}

    public func record(_ event: HTTPDiagnosticEvent) {
        let id = event.requestID.uuidString
        let method = event.method.rawValue
        let outcome = event.outcome.rawValue
        let code = event.failure?.diagnosticCode ?? "none"
        logger.debug("""
        id=\(id, privacy: .public) method=\(method, privacy: .public) \
        outcome=\(outcome, privacy: .public) status=\(event.statusCode ?? 0) \
        duration=\(event.duration) bytes=\(event.receivedBytes) failure=\(code, privacy: .public)
        """)
    }
}

private extension HTTPError {
    var diagnosticCode: String {
        switch self {
        case .invalidRequest: "invalid-request"
        case .invalidPolicy: "invalid-policy"
        case .invalidResponse: "invalid-response"
        case .unexpectedResponseURL: "unexpected-response-url"
        case .redirectRejected: "redirect-rejected"
        case .responseTooLarge: "response-too-large"
        case .connection(let code): "connection-\(code.rawValue)"
        case .transportFailure: "transport-failure"
        case .status(let code, _): "http-\(code)"
        }
    }
}
