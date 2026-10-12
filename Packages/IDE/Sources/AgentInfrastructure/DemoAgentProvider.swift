import Foundation
import IDEApplication
import IDEDomain

/// Offline UI demonstration. Performs no model, filesystem, shell or network operation.
public actor DemoAgentProvider: CodingAgentProvider {
    public nonisolated let info = AgentProviderInfo(name: "Local demo", isDemo: true)
    private let delay: Duration
    private var producers: [UUID: Task<Void, Never>] = [:]
    public var activeCount: Int { producers.count }

    public init(delay: Duration = .milliseconds(55)) { self.delay = delay }

    public func events(for request: AgentRequest) async throws -> AsyncThrowingStream<AgentEvent, Error> {
        try Task.checkCancellation()
        let (stream, continuation) = AsyncThrowingStream<AgentEvent, Error>.makeStream()
        let textID = UUID(), codeID = UUID(), toolID = UUID(), endingID = UUID()
        let selected = request.contexts.first
        let response = selected.map {
            "Attached selection: \($0.name), version \($0.version). This is an immutable editor snapshot.\n\n"
        } ?? "This is a local demonstration of the agent chat.\n\n"
        let text = response + "The response streams into this message. "
            + "You can select text, copy code and keep reading earlier messages."
        let code = selected?.text ?? """
        struct Greeting {
            let name: String

            func message() -> String {
                "Hello, \\(name)!"
            }
        }
        """
        let language = selected == nil || selected?.path.hasSuffix(".swift") == true ? "swift" : "text"
        let delay = delay
        producers[request.id] = Task {
            do {
                continuation.yield(.toolChanged(block: toolID, tool: .init(
                    title: "Prepare demonstration",
                    detail: "Simulated activity · no files or commands are executed.",
                    state: .running
                )))
                for chunk in Self.chunks(text) {
                    try Task.checkCancellation()
                    continuation.yield(.textDelta(block: textID, text: chunk))
                    try await Task.sleep(for: delay)
                }
                for chunk in Self.chunks(code) {
                    try Task.checkCancellation()
                    continuation.yield(.codeDelta(block: codeID, language: language, text: chunk))
                    try await Task.sleep(for: delay)
                }
                continuation.yield(.toolChanged(block: toolID, tool: .init(
                    title: "Demonstration complete",
                    detail: "Simulated result · no API calls or file changes.",
                    state: .succeeded
                )))
                continuation.yield(.textDelta(
                    block: endingID,
                    text: "A real provider can be connected through the same session interface later."
                ))
                continuation.yield(.finished)
                continuation.finish()
            } catch { continuation.finish(throwing: error) }
        }
        continuation.onTermination = { [weak self] _ in Task { await self?.cancel(requestID: request.id) } }

        return stream
    }

    public func cancel(requestID: UUID) async {
        guard let producer = producers[requestID] else { return }

        producer.cancel()
        await producer.value
        producers[requestID] = nil
    }

    private nonisolated static func chunks(_ text: String) -> [String] {
        var chunks: [String] = []
        var current = ""
        let size = max(18, (text.count + 39) / 40)
        for character in text {
            current.append(character)
            if current.count >= size {
                chunks.append(current)
                current = ""
            }
        }
        if !current.isEmpty { chunks.append(current) }

        return chunks
    }
}
