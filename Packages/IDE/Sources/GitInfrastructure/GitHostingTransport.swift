import Foundation
import IDEApplication

public struct GitHostingHTTPResponse: Sendable {
    public let status: Int
    public let data: Data
    public let headers: [String: String]

    public init(status: Int, data: Data, headers: [String: String] = [:]) {
        self.status = status
        self.data = data
        self.headers = headers
    }
}

public protocol GitHostingTransport: Sendable {
    func send(_ request: URLRequest) async throws -> GitHostingHTTPResponse
}

public actor GitHostingURLSessionTransport: GitHostingTransport {
    public init() {}

    public func send(_ request: URLRequest) async throws -> GitHostingHTTPResponse {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config, delegate: GitHostingRedirectRefusal(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.url == request.url,
              !(300...399).contains(http.statusCode), http.expectedContentLength <= 2_000_000 else {
            throw GitInspectionError.failed("Hosting response redirected or exceeds the 2 MB limit.")
        }

        var data = Data()
        for try await byte in bytes {
            if data.count % 4096 == 0 { try Task.checkCancellation() }
            guard data.count < 2_000_000 else { throw GitInspectionError.failed("Hosting response exceeds 2 MB.") }

            data.append(byte)
        }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            headers[String(describing: key).lowercased()] = String(describing: value)
        }

        return .init(status: http.statusCode, data: data, headers: headers)
    }
}

private final class GitHostingRedirectRefusal: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
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
