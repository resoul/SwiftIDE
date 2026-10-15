import Foundation
import HTTPInfrastructure

final class DiagnosticRecorder: HTTPDiagnostics, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [HTTPDiagnosticEvent] = []

    var events: [HTTPDiagnosticEvent] { lock.withLock { recorded } }

    func record(_ event: HTTPDiagnosticEvent) { lock.withLock { recorded.append(event) } }
}

struct HTTPFixture: Sendable {
    var status = 200
    var headers: [String: String] = [:]
    var chunks: [Data] = []
    var failure: URLError?
    var holdOpen = false
    var redirect: URL?
    var responseURL: URL?
    var nonHTTP = false
}

/// Each UUID address has its own script, allowing tests to run concurrently without a live server.
final class HTTPFixtureRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var fixtures: [URL: HTTPFixture] = [:]
    private var starts: [URL: Int] = [:]
    private var stops: [URL: Int] = [:]

    func register(_ fixture: HTTPFixture) -> URL {
        let url = URL(string: "https://fixture.invalid/\(UUID())")!
        lock.withLock { fixtures[url] = fixture }

        return url
    }

    func start(_ url: URL) -> HTTPFixture? {
        lock.withLock {
            starts[url, default: 0] += 1

            return fixtures[url]
        }
    }

    func count(_ url: URL) -> Int { lock.withLock { starts[url, default: 0] } }

    func stop(_ url: URL) { lock.withLock { stops[url, default: 0] += 1 } }

    func stopped(_ url: URL) -> Bool { lock.withLock { stops[url, default: 0] > 0 } }
}

final class HTTPStubProtocol: URLProtocol, @unchecked Sendable {
    static let registry = HTTPFixtureRegistry()

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let fixture = Self.registry.start(url) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))

            return
        }

        if let failure = fixture.failure {
            client?.urlProtocol(self, didFailWithError: failure)

            return
        }

        let response: URLResponse
        if fixture.nonHTTP {
            response = URLResponse(url: url, mimeType: "text/plain", expectedContentLength: -1, textEncodingName: nil)
        } else {
            response = HTTPURLResponse(
                url: fixture.responseURL ?? url,
                statusCode: fixture.status,
                httpVersion: "HTTP/1.1",
                headerFields: fixture.headers
            )!
        }

        if let redirect = fixture.redirect, let http = response as? HTTPURLResponse {
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: redirect), redirectResponse: http)
        }

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for data in fixture.chunks { client?.urlProtocol(self, didLoad: data) }
        if !fixture.holdOpen { client?.urlProtocolDidFinishLoading(self) }
    }

    override func stopLoading() {
        if let url = request.url { Self.registry.stop(url) }
    }
}
