import Foundation
import Testing
@testable import HTTPInfrastructure

struct HTTPTransportTests {
    private func transport(_ recorder: DiagnosticRecorder) -> URLSessionHTTPTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HTTPStubProtocol.self]

        return URLSessionHTTPTransport(configuration: configuration, diagnostics: recorder)
    }

    @Test func rawStatusesHeadersAndRetryAfterRemainAvailableWithoutRetries() async throws {
        let recorder = DiagnosticRecorder()
        let transport = transport(recorder)
        let url = HTTPStubProtocol.registry.register(.init(
            status: 429,
            headers: ["Retry-After": "120", "X-Trace": "response-secret"],
            chunks: [Data("private response".utf8)]
        ))
        let call = HTTPRequest(request: URLRequest(url: url))
        let response = try await transport.send(call)
        #expect(response.status == 429 && response.headers["x-trace"] == "response-secret")
        #expect(response.data == Data("private response".utf8))
        #expect(throws: HTTPError.status(code: 429, retryAfter: 120)) { try response.requireSuccess() }
        #expect(HTTPStubProtocol.registry.count(url) == 1)
        let event = try #require(recorder.events.first)
        #expect(recorder.events.count == 1 && event.requestID == call.id)
        #expect(event.statusCode == 429 && event.outcome == .response && event.duration >= 0)
        #expect(event.receivedBytes == response.data.count)
        #expect(!String(reflecting: event).contains("secret"))
        let unchanged = HTTPStubProtocol.registry.register(.init(status: 304))
        let raw = try await transport.send(.init(request: URLRequest(url: unchanged)))
        #expect(raw.status == 304, "a cache status is not a redirect or a transport failure")
    }

    @Test func declaredAndStreamingBodyLimitsRejectOversizeResponses() async throws {
        for (headers, chunks, received) in [
            (["Content-Length": "5000"], [], 0),
            ([:], [Data([1, 2]), Data([3, 4])], 3)
        ] {
            let recorder = DiagnosticRecorder()
            let url = HTTPStubProtocol.registry.register(.init(headers: headers, chunks: chunks))
            let call = HTTPRequest(request: URLRequest(url: url), policy: .init(maximumResponseBytes: 3))
            await #expect(throws: HTTPError.responseTooLarge(maximumBytes: 3)) {
                try await transport(recorder).send(call)
            }
            let event = try #require(recorder.events.first)
            #expect(recorder.events.count == 1 && event.outcome == .failed)
            #expect(event.receivedBytes == received)
        }
        let url = HTTPStubProtocol.registry.register(.init(chunks: [Data([1, 2, 3])]))
        let response = try await transport(DiagnosticRecorder()).send(.init(
            request: URLRequest(url: url),
            policy: .init(maximumResponseBytes: 3)
        ))
        #expect(response.data.count == 3)
    }

    @Test func redirectsAndMismatchedResponsesCannotForwardCredentials() async throws {
        let recorder = DiagnosticRecorder()
        let transport = transport(recorder)
        let destination = HTTPStubProtocol.registry.register(.init())
        let redirect = HTTPStubProtocol.registry.register(.init(status: 302, redirect: destination))
        var request = URLRequest(url: redirect)
        request.setValue("Bearer fixture-secret", forHTTPHeaderField: "Authorization")
        await #expect(throws: HTTPError.redirectRejected(status: 302)) {
            try await transport.send(.init(request: request))
        }
        #expect(HTTPStubProtocol.registry.count(destination) == 0)
        let mismatch = HTTPStubProtocol.registry.register(.init(responseURL: destination))
        await #expect(throws: HTTPError.unexpectedResponseURL) {
            try await transport.send(.init(request: URLRequest(url: mismatch)))
        }
        let nonHTTP = HTTPStubProtocol.registry.register(.init(nonHTTP: true))
        await #expect(throws: HTTPError.invalidResponse) {
            try await transport.send(.init(request: URLRequest(url: nonHTTP)))
        }
        #expect(recorder.events.count == 3)
    }

    @Test func connectionErrorsAndDiagnosticsDiscardSensitiveRequestAndErrorDetails() async throws {
        let recorder = DiagnosticRecorder()
        let url = HTTPStubProtocol.registry.register(.init(failure: URLError(.timedOut, userInfo: [
            NSLocalizedDescriptionKey: "fixture-secret-description",
            NSURLErrorFailingURLStringErrorKey: "https://private.example/?token=fixture-secret"
        ])))
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data("fixture-secret-body".utf8)
        request.setValue("Bearer fixture-secret-token", forHTTPHeaderField: "Authorization")
        request.setValue("fixture-secret-token", forHTTPHeaderField: "PRIVATE-TOKEN")
        await #expect(throws: HTTPError.connection(.timedOut)) {
            try await transport(recorder).send(.init(request: request))
        }
        let event = try #require(recorder.events.first)
        #expect(event.method == .post && event.failure == .connection(.timedOut))
        #expect(!String(reflecting: event).contains("fixture-secret"))
        #expect(!String(reflecting: event).contains("private.example"))
        #expect(!HTTPError.connection(.timedOut).localizedDescription.contains("fixture-secret"))
        #expect(HTTPStubProtocol.registry.count(url) == 1, "failed writes are not retried")
    }

    @Test func cancellingOneRequestDoesNotInvalidateTheSharedSession() async throws {
        let recorder = DiagnosticRecorder()
        let transport = transport(recorder)
        let slow = HTTPStubProtocol.registry.register(.init(holdOpen: true))
        let task = Task { try await transport.send(.init(request: URLRequest(url: slow))) }
        let deadline = ContinuousClock.now + .seconds(3)
        while HTTPStubProtocol.registry.count(slow) == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(HTTPStubProtocol.registry.count(slow) == 1)
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        let fast = HTTPStubProtocol.registry.register(.init(chunks: [Data("ok".utf8)]))
        let response = try await transport.send(.init(request: URLRequest(url: fast)))
        #expect(response.data == Data("ok".utf8))
        #expect(recorder.events.count == 2)
        #expect(recorder.events[0].outcome == .cancelled && recorder.events[0].failure == nil)
        #expect(recorder.events[1].outcome == .response)
        #expect(HTTPStubProtocol.registry.stopped(slow), "cancellation also stops the underlying data task")
    }

    @Test func invalidPoliciesAndAddressesFailBeforeSending() async throws {
        let recorder = DiagnosticRecorder()
        let transport = transport(recorder)
        let url = HTTPStubProtocol.registry.register(.init())
        for policy in [
            HTTPRequestPolicy(timeout: 0),
            .init(timeout: .infinity),
            .init(maximumResponseBytes: -1)
        ] {
            await #expect(throws: HTTPError.invalidPolicy) {
                try await transport.send(.init(request: URLRequest(url: url), policy: policy))
            }
        }
        for address in ["file:///tmp/private-file", "https://user:fixture-secret@example.com"] {
            let url = try #require(URL(string: address))
            await #expect(throws: HTTPError.invalidRequest) {
                try await transport.send(.init(request: URLRequest(url: url)))
            }
        }
        #expect(HTTPStubProtocol.registry.count(url) == 0)
        #expect(recorder.events.count == 5)
    }
}
