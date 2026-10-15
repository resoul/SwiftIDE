import Foundation

/// Per-call limits. There are no implicit retries or automatic credential refreshes.
public struct HTTPRequestPolicy: Sendable, Equatable {
    public let timeout: TimeInterval
    public let maximumResponseBytes: Int

    public init(timeout: TimeInterval = 30, maximumResponseBytes: Int = 2_000_000) {
        self.timeout = timeout
        self.maximumResponseBytes = maximumResponseBytes
    }
}

/// The identifier follows one logical call without adding tracking headers to a third-party API.
public struct HTTPRequest: Sendable {
    public let id: UUID
    public let request: URLRequest
    public let policy: HTTPRequestPolicy

    public init(id: UUID = UUID(), request: URLRequest, policy: HTTPRequestPolicy = .init()) {
        self.id = id
        self.request = request
        self.policy = policy
    }
}

public protocol HTTPTransport: Sendable {
    /// Returns all HTTP statuses for the service client to interpret. Cancellation throws CancellationError.
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}
