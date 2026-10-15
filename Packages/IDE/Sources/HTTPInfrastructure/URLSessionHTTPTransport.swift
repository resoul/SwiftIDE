import Foundation

/// A reusable ephemeral session. Service-specific auth and decoding stay in the API clients.
public actor URLSessionHTTPTransport: HTTPTransport {
    private let session: URLSession
    private let diagnostics: any HTTPDiagnostics

    /// Resource timeout bounds the whole transfer; HTTPRequestPolicy controls the request timeout.
    public init(resourceTimeout: TimeInterval = 60, diagnostics: any HTTPDiagnostics = OSLogHTTPDiagnostics()) {
        precondition(resourceTimeout.isFinite && resourceTimeout > 0)
        self.diagnostics = diagnostics
        session = Self.makeSession(configuration: .ephemeral, resourceTimeout: resourceTimeout)
    }

    /// URLProtocol fixtures exercise the real URLSession path without opening network connections.
    init(configuration: URLSessionConfiguration, diagnostics: any HTTPDiagnostics) {
        self.diagnostics = diagnostics
        session = Self.makeSession(configuration: configuration)
    }

    deinit { session.invalidateAndCancel() }

    public func send(_ call: HTTPRequest) async throws -> HTTPResponse {
        let started = ContinuousClock.now
        var status: Int?
        var received = 0
        var outcome = HTTPDiagnosticEvent.Outcome.failed
        var failure: HTTPError?
        defer {
            let elapsed = started.duration(to: .now).components
            diagnostics.record(.init(
                requestID: call.id,
                method: .init(rawValue: call.request.httpMethod ?? "GET") ?? .other,
                duration: Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18,
                statusCode: status,
                receivedBytes: received,
                outcome: outcome,
                failure: failure
            ))
        }
        do {
            try Task.checkCancellation()
            guard call.policy.timeout.isFinite, call.policy.timeout > 0,
                  call.policy.maximumResponseBytes >= 0 else { throw HTTPError.invalidPolicy }

            guard let url = call.request.url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
                  let host = components.host, !host.isEmpty,
                  components.user == nil, components.password == nil else { throw HTTPError.invalidRequest }

            var request = call.request
            request.timeoutInterval = call.policy.timeout
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.httpShouldHandleCookies = false
            let (bytes, response) = try await session.bytes(for: request)
            defer { bytes.task.cancel() }
            guard let http = response as? HTTPURLResponse else { throw HTTPError.invalidResponse }

            status = http.statusCode
            guard http.url == url else { throw HTTPError.unexpectedResponseURL }

            guard !(300...399).contains(http.statusCode) || http.statusCode == 304 else {
                throw HTTPError.redirectRejected(status: http.statusCode)
            }

            guard http.expectedContentLength <= Int64(call.policy.maximumResponseBytes) else {
                throw HTTPError.responseTooLarge(maximumBytes: call.policy.maximumResponseBytes)
            }

            var data = Data()
            for try await byte in bytes {
                if received % 4096 == 0 { try Task.checkCancellation() }
                guard received < call.policy.maximumResponseBytes else {
                    throw HTTPError.responseTooLarge(maximumBytes: call.policy.maximumResponseBytes)
                }

                data.append(byte)
                received += 1
            }
            try Task.checkCancellation()
            var headers: [String: String] = [:]
            for (key, value) in http.allHeaderFields {
                headers[String(describing: key)] = String(describing: value)
            }
            outcome = .response

            return .init(status: http.statusCode, data: data, headers: headers)
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                outcome = .cancelled

                throw CancellationError()
            }

            let sanitized = error as? HTTPError ?? (error as? URLError)
                .map { .connection($0.code) } ?? .transportFailure
            failure = sanitized

            throw sanitized
        }
    }

    private static func makeSession(
        configuration: URLSessionConfiguration,
        resourceTimeout: TimeInterval = 60
    ) -> URLSession {
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData

        return URLSession(configuration: configuration, delegate: RedirectRefusal(), delegateQueue: nil)
    }
}

private final class RedirectRefusal: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
