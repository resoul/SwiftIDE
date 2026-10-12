import Foundation
import Testing
@testable import IDEApplication

@Suite(.serialized) @MainActor
struct GitCloneTests {
    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        try #require(predicate())
    }

    private let request = GitCloneRequest(source: "https://host/repo.git", parent: "/projects", name: "repo")

    @Test func duplicatesCancellationFailureAndRetryOnlyOpenAfterSuccess() async throws {
        let service = CloneFixture(), model = GitClone(service: service)
        defer { model.stop() }
        var opened: [String] = []
        model.onSuccess = { opened.append($0) }
        model.start(request)
        model.start(request)
        try await wait { model.output.contains("started") }
        #expect(await service.calls == 1)
        model.cancel()
        #expect(model.state == .cancelling)
        await service.complete(.success("/projects/repo"))
        try await wait { model.state == .cancelled }
        #expect(opened.isEmpty)
        model.start(request)
        try await wait { model.output.contains("started") }
        await service.complete(.failure(GitInspectionError.failed("Authentication failed")))
        try await wait { model.state == .failed("Authentication failed") }
        #expect(opened.isEmpty)
        model.start(request)
        try await wait { model.output.contains("started") }
        await service.complete(.success("/projects/repo"))
        try await wait { model.state == .succeeded }
        #expect(opened == ["/projects/repo"] && model.destination == request.destination)
    }

    @Test func stoppedOwnerRejectsLateResultsAndInvalidRequestNeverStarts() async throws {
        let service = CloneFixture(), model = GitClone(service: service)
        var opened = false
        model.onSuccess = { _ in opened = true }
        model.start(.init(source: request.source, parent: request.parent, name: "../escape"))
        #expect(await service.calls == 0)
        if case .failed = model.state {} else { Issue.record("Invalid destination must fail") }
        model.start(request)
        try await wait { model.output.contains("started") }
        let output = model.output
        model.stop()
        await service.complete(.success("/projects/repo"))
        for _ in 0..<20 { await Task.yield() }
        #expect(!opened && model.output == output)
    }
}

private actor CloneFixture: GitCloning {
    private(set) var calls = 0
    private var continuation: CheckedContinuation<String, any Error>?

    func clone(_ request: GitCloneRequest, output: @escaping @Sendable (String) -> Void) async throws -> String {
        calls += 1

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            output("started\n")
        }
    }

    func complete(_ result: Result<String, any Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}
