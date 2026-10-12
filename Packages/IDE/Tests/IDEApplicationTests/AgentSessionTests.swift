import Foundation
import IDEDomain
import IDETestSupport
import Testing
@testable import IDEApplication

private actor ControlledAgent: CodingAgentProvider {
    nonisolated let info = AgentProviderInfo(name: "Test provider", isDemo: true)
    var requests: [AgentRequest] = []
    var cancellations: [UUID] = []
    private var streams: [UUID: AsyncThrowingStream<AgentEvent, Error>.Continuation] = [:]

    func events(for request: AgentRequest) async throws -> AsyncThrowingStream<AgentEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<AgentEvent, Error>.makeStream()
        requests.append(request)
        streams[request.id] = continuation

        return stream
    }

    func cancel(requestID: UUID) async {
        cancellations.append(requestID)
        streams[requestID]?.finish()
    }

    func emit(_ event: AgentEvent, request index: Int = 0) { streams[requests[index].id]?.yield(event) }

    func fail(_ index: Int = 0) {
        streams[requests[index].id]?.finish(throwing: AgentSelectionError("fixture failure"))
    }
}

@MainActor
struct AgentSessionTests {
    private func wait(_ predicate: () async -> Bool) async throws {
        let end = ContinuousClock.now + .seconds(5)
        while !(await predicate()), ContinuousClock.now < end { await Task.yield() }
        try #require(await predicate())
    }

    @Test func streamingUpdatesStableBlocksAndKeepsTheCapturedUserSelection() async throws {
        let provider = ControlledAgent(), session = AgentSession(provider: provider)
        defer { session.stop() }
        let document = DocumentSession(
            path: "/workspace/a.swift",
            backend: StringDocumentBackend(loadedText: "original")
        )
        let context = try document.captureAgentSelection(in: .init(location: 0, length: 8))
        #expect(session.attach(context))
        session.setDraft("Explain this selection")
        #expect(session.send() && !session.send() && session.draft.isEmpty && session.contexts.isEmpty)
        let messageID = session.messages.last?.id, block = UUID(), code = UUID(), tool = UUID()
        try await wait { await provider.requests.count == 1 }
        try document.replaceText("changed", expectedVersion: 0)
        await provider.emit(.textDelta(block: block, text: "Hello "))
        await provider.emit(.textDelta(block: block, text: "world"))
        await provider.emit(.codeDelta(block: code, language: "swift", text: "let a = 1\n"))
        await provider.emit(.toolChanged(
            block: tool,
            tool: .init(title: "Example", detail: "simulated", state: .running)
        ))
        await provider.emit(.toolChanged(
            block: tool,
            tool: .init(title: "Example", detail: "complete", state: .succeeded)
        ))
        await provider.emit(.finished)
        try await wait { session.state == .ready }
        #expect(session.messages.last?.id == messageID && session.messages.last?.blocks.count == 3)
        #expect(session.messages.last?.blocks.first?.content == .text("Hello world"))
        #expect(session.messages.last?.status == .complete)
        let request = try #require(await provider.requests.first)
        #expect(request.contexts == [context] && request.contexts[0].text == "original")
        #expect(request.contexts[0].version == 0 && document.version == 1)
        #expect(session.messages.first?.contexts == [context])
        #expect(await provider.cancellations.contains(request.id))
        session.stop()
        #expect(session.state == .stopped && session.messages.last?.status == .complete)
    }

    @Test func cancelPreservesPartialOutputAndTheNextDraftAndRejectsOldEvents() async throws {
        let provider = ControlledAgent(), session = AgentSession(provider: provider)
        defer { session.stop() }
        session.setDraft("first")
        #expect(session.send())
        try await wait { await provider.requests.count == 1 }
        let block = UUID()
        await provider.emit(.textDelta(block: block, text: "partial"))
        await provider.emit(.toolChanged(block: UUID(), tool: .init(title: "Task", detail: "running", state: .running)))
        try await wait { session.messages.last?.blocks.count == 2 }
        session.setDraft("next draft")
        session.cancel()
        try await wait { session.state == .ready }
        #expect(session.messages.last?.status == .cancelled && session.draft == "next draft")
        #expect(session.messages.last?.blocks.first?.content == .text("partial"))
        #expect(session.send())
        try await wait { await provider.requests.count == 2 }
        await provider.emit(.textDelta(block: block, text: " stale"), request: 0)
        await provider.emit(.textDelta(block: UUID(), text: "current"), request: 1)
        await provider.emit(.finished, request: 1)
        try await wait { session.state == .ready }
        #expect(session.messages[1].blocks.first?.content == .text("partial"))
        #expect(session.messages.last?.plainText == "current")
    }

    @Test func errorsKeepPartialTextAndStopPreventsAnyFurtherRequest() async throws {
        let provider = ControlledAgent(), session = AgentSession(provider: provider)
        session.setDraft("question")
        #expect(session.send())
        try await wait { await provider.requests.count == 1 }
        await provider.emit(.textDelta(block: UUID(), text: "partial answer"))
        await provider.fail()
        try await wait {
            if case .failed = session.state { return true }

            return false
        }
        #expect(session.messages.last?.status == .failed && session.messages.last?.plainText == "partial answer")
        session.setDraft("try again")
        #expect(session.send())
        try await wait { await provider.requests.count == 2 }
        session.stop()
        await provider.emit(.textDelta(block: UUID(), text: "closed"), request: 1)
        for _ in 0..<10 { await Task.yield() }
        #expect(session.state == .stopped && !session.canSend && !session.send())
        #expect(session.messages.last?.blocks.isEmpty == true)
    }

    @Test func oversizedResponseAndChangedBlockTypeAreRejected() async throws {
        let provider = ControlledAgent(), session = AgentSession(provider: provider)
        defer { session.stop() }
        session.setDraft(String(repeating: "x", count: 64_001))
        #expect(!session.canSend && !session.send())
        session.setDraft("bounded")
        #expect(session.send())
        try await wait { await provider.requests.count == 1 }
        await provider.emit(.textDelta(block: UUID(), text: String(repeating: "x", count: 256_001)))
        try await wait {
            if case .failed = session.state { return true }

            return false
        }
        #expect(session.messages.last?.blocks.isEmpty == true)
        session.setDraft("types")
        #expect(session.send())
        try await wait { await provider.requests.count == 2 }
        let block = UUID()
        await provider.emit(.textDelta(block: block, text: "keep"), request: 1)
        await provider.emit(.codeDelta(block: block, language: "swift", text: "wrong"), request: 1)
        try await wait {
            if case .failed = session.state { return true }

            return false
        }
        #expect(session.messages.last?.blocks.first?.content == .text("keep"))
    }

    @Test func historyAndDraftContextAreBoundedAndClearIsExplicit() async throws {
        let provider = ControlledAgent(), session = AgentSession(provider: provider)
        defer { session.stop() }
        let context = AgentContext(
            documentID: .init(),
            path: "/a",
            version: 0,
            range: .init(location: 0, length: 1),
            text: "x"
        )
        for _ in 0..<4 {
            #expect(session.attach(.init(
                documentID: context.documentID,
                path: context.path,
                version: context.version,
                range: context.range,
                text: context.text
            )))
        }
        #expect(!session.attach(context) && session.contexts.count == 4)
        for i in 0..<103 {
            session.setDraft("turn \(i)")
            #expect(session.send())
            try await wait { await provider.requests.count == i + 1 }
            await provider.emit(.finished, request: i)
            try await wait { session.state == .ready }
        }
        #expect(session.messages.count == 200 && session.messages.first?.plainText == "turn 3")
        session.clear()
        #expect(session.messages.isEmpty && session.contexts.isEmpty && session.draft.isEmpty)
    }

    @Test func selectionCaptureChecksUnicodeCompositionAndRangeWithoutChangingTheDocument() throws {
        let backend = StringDocumentBackend(loadedText: "A🙂B")
        let document = DocumentSession(path: "/a.swift", backend: backend)
        let selection = try document.captureAgentSelection(in: .init(location: 1, length: 2))
        #expect(selection.text == "🙂" && selection.version == 0 && !document.isDirty)
        #expect(throws: AgentSelectionError.self) {
            try document.captureAgentSelection(in: .init(location: 2, length: 1))
        }
        #expect(throws: AgentSelectionError.self) {
            try document.captureAgentSelection(in: .init(location: 5, length: 1))
        }
        backend.simulateComposition(.began)
        #expect(throws: DocumentError.compositionInProgress) {
            try document.captureAgentSelection(in: .init(location: 0, length: 1))
        }
        backend.simulateComposition(.ended)
        #expect(document.version == 0 && !document.isDirty)
    }

    @Test func capturingASmallSelectionFromALargeDocumentNeverMaterializesTheWholeText() throws {
        let backend = StringDocumentBackend(loadedText: String(repeating: "a", count: 2_000_000) + "selected")
        let document = DocumentSession(path: "/large.swift", backend: backend)
        let before = backend.textMaterializations
        let selected = try document.captureAgentSelection(in: .init(location: 2_000_000, length: 8))
        #expect(selected.text == "selected" && backend.textMaterializations == before)
    }
}
