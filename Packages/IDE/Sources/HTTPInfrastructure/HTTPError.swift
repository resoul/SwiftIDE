import Foundation

/// Contains no URLs, credentials, response bodies or underlying NSError userInfo.
public enum HTTPError: Error, Sendable, Equatable, LocalizedError {
    case invalidRequest
    case invalidPolicy
    case invalidResponse
    case unexpectedResponseURL
    case redirectRejected(status: Int)
    case responseTooLarge(maximumBytes: Int)
    case connection(URLError.Code)
    case transportFailure
    case status(code: Int, retryAfter: TimeInterval?)

    public var errorDescription: String? {
        switch self {
        case .invalidRequest: "Invalid HTTP request."
        case .invalidPolicy: "Invalid HTTP timeout or response limit."
        case .invalidResponse: "The server did not return an HTTP response."
        case .unexpectedResponseURL: "The response address differs from the request."
        case .redirectRejected: "HTTP redirects are disabled."
        case .responseTooLarge: "The HTTP response exceeds the configured size limit."
        case .connection(let code): "HTTP connection failed (\(code.rawValue))."
        case .transportFailure: "HTTP transport failed."
        case .status(let code, _): "HTTP status \(code)."
        }
    }
}
