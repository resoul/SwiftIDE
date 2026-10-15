import Foundation
import HTTPInfrastructure

/// Retained service names keep existing client/test injection points source-compatible.
public typealias GitHostingHTTPResponse = HTTPResponse

public protocol GitHostingTransport: Sendable {
    func send(_ request: URLRequest) async throws -> GitHostingHTTPResponse
}

/// Hosting supplies its limits; HTTPInfrastructure owns session lifetime and response handling.
public struct GitHostingURLSessionTransport: GitHostingTransport {
    private let transport: any HTTPTransport
    private let policy = HTTPRequestPolicy(timeout: 30, maximumResponseBytes: 2_000_000)

    public init(transport: any HTTPTransport = URLSessionHTTPTransport()) { self.transport = transport }

    public func send(_ request: URLRequest) async throws -> GitHostingHTTPResponse {
        try await transport.send(HTTPRequest(request: request, policy: policy))
    }
}
