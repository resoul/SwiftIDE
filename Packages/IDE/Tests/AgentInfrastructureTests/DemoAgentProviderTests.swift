import Foundation
import IDEApplication
import IDEDomain
import Testing
@testable import AgentInfrastructure

struct DemoAgentProviderTests {
    @Test func demoProducesStructuredBlocksAndFinishesWithoutAnExternalRuntime() async throws {
        let provider = DemoAgentProvider(delay: .milliseconds(1))
        let request = AgentRequest(prompt: "hello", contexts: [])
        var events: [AgentEvent] = []
        for try await event in try await provider.events(for: request) { events.append(event) }
        #expect(provider.info.isDemo && events.last == .finished)
        #expect(events.contains {
            if case .codeDelta = $0 { return true }

            return false
        })
        #expect(events.contains {
            if case .toolChanged(_, let tool) = $0 { return tool.state == .succeeded }

            return false
        })
        await provider.cancel(requestID: request.id)
        #expect(await provider.activeCount == 0)
    }

    @Test func cancellingDemoReleasesItsProducerAndNeverFinishesAnAnswer() async throws {
        let provider = DemoAgentProvider(delay: .seconds(10))
        let request = AgentRequest(prompt: "cancel", contexts: [])
        let stream = try await provider.events(for: request)
        var iterator = stream.makeAsyncIterator()
        let first = try await iterator.next()
        #expect(first != nil)
        await provider.cancel(requestID: request.id)
        #expect(await provider.activeCount == 0)
        var completed = false
        do { while let event = try await iterator.next() { if event == .finished { completed = true } } } catch {}
        #expect(!completed)
    }
}
