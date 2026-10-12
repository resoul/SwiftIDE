import Foundation
import IDEDomain

public struct AgentProviderInfo: Equatable, Sendable {
    public let name: String
    public let isDemo: Bool

    public init(name: String, isDemo: Bool) {
        self.name = name
        self.isDemo = isDemo
    }
}

/// Adapters own parsing, authentication and cancellation of their producer/runtime.
public protocol CodingAgentProvider: Sendable {
    var info: AgentProviderInfo { get }

    func events(for request: AgentRequest) async throws -> AsyncThrowingStream<AgentEvent, Error>

    func cancel(requestID: UUID) async
}

public enum AgentSessionState: Equatable, Sendable {
    case ready, running, cancelling, stopped
    case failed(String)
}

/// One project's in-memory conversation, independent of panel visibility and AppKit.
@MainActor
public final class AgentSession {
    public let info: AgentProviderInfo
    public private(set) var messages: [AgentMessage] = []
    public private(set) var state = AgentSessionState.ready
    public private(set) var draft = ""
    public private(set) var contexts: [AgentContext] = []
    public private(set) var inputError: String?
    public var canSend: Bool {
        state != .stopped && activeRequest == nil && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && draft.utf8.count <= 64_000
    }
    public var canClear: Bool { activeRequest == nil && state != .stopped }
    private let provider: any CodingAgentProvider
    private var activeRequest: UUID?
    private var responseID: UUID?
    private var task: Task<Void, Never>?
    private var cancellation: Task<Void, Never>?
    private var replyBytes = 0
    private var observers: [UUID: () -> Void] = [:]

    public init(provider: any CodingAgentProvider) {
        self.provider = provider
        info = provider.info
    }

    public func setDraft(_ value: String) {
        guard state != .stopped, draft != value else { return }

        draft = value
        inputError = value.utf8.count > 64_000 ? "Message limit: 64 KB." : nil
        changed()
    }

    @discardableResult
    public func attach(_ context: AgentContext) -> Bool {
        guard state != .stopped else { return false }

        guard !contexts.contains(where: { $0.id == context.id }) else {
            inputError = "This selection is already attached."
            changed()

            return false
        }

        guard contexts.count < 4,
              context.text.utf8.count + contexts.reduce(0, { $0 + $1.text.utf8.count }) <= 64_000 else {
            inputError = "Context limit: four selections and 64 KB in total."
            changed()

            return false
        }

        contexts.append(context)
        inputError = nil
        changed()

        return true
    }

    public func removeContext(_ id: UUID) {
        contexts.removeAll { $0.id == id }
        inputError = nil
        changed()
    }

    public func reportInputError(_ message: String) {
        inputError = String(message.prefix(1000))
        changed()
    }

    @discardableResult
    public func send() -> Bool {
        guard canSend else { return false }

        let request = AgentRequest(prompt: draft, contexts: contexts)
        messages.append(.init(role: .user, blocks: [.init(content: .text(draft))], contexts: contexts))
        let response = AgentMessage(role: .assistant, blocks: [], status: .streaming)
        messages.append(response)
        // Bounded history; evict complete earlier turns only, never the active response.
        while messages.count > 200 || messages.dropLast(2).reduce(0, {
            $0 + $1.plainText.utf8.count + $1.contexts.reduce(0, { $0 + $1.text.utf8.count })
        }) > 4_000_000 {
            messages.removeFirst(2)
        }
        draft = ""
        contexts = []
        inputError = nil
        activeRequest = request.id
        responseID = response.id
        replyBytes = 0
        state = .running
        changed()
        task = Task { [weak self, provider] in
            do {
                let stream = try await provider.events(for: request)
                for try await event in stream {
                    try Task.checkCancellation()
                    guard let self, activeRequest == request.id, state == .running else { return }

                    if event == .finished {
                        if messages.last?.blocks.contains(where: {
                            if case .tool(let tool) = $0.content { return tool.state == .running }

                            return false
                        }) == true { throw AgentSessionFailure("The provider ended with an activity still running.") }

                        await provider.cancel(requestID: request.id)
                        guard activeRequest == request.id, state == .running else { return }

                        complete(request.id)

                        return
                    }

                    try apply(event)
                }
                try Task.checkCancellation()
                throw AgentSessionFailure("The response ended without a completion event.")
            } catch {
                await provider.cancel(requestID: request.id)
                guard let self, activeRequest == request.id, state == .running else { return }

                finishResponse(status: error is CancellationError ? .cancelled : .failed)
                activeRequest = nil
                task = nil
                state = error is CancellationError ? .ready : .failed(String(error.localizedDescription.prefix(1000)))
                changed()
            }
        }

        return true
    }

    private func apply(_ event: AgentEvent) throws {
        guard let index = messages.firstIndex(where: { $0.id == responseID }) else { return }

        let id: UUID
        let content: AgentContent
        switch event {
        case .textDelta(let block, let delta):
            id = block
            try count(delta.utf8.count)
            if let previous = messages[index].blocks.first(where: { $0.id == block }) {
                guard case .text(let text) = previous.content else { throw AgentSessionFailure("Block type changed.") }

                content = .text(text + delta)
            } else { content = .text(delta) }
        case .codeDelta(let block, let language, let delta):
            id = block
            try count(delta.utf8.count)
            guard language.utf8.count <= 128 else { throw AgentSessionFailure("Code language label is too long.") }

            if let previous = messages[index].blocks.first(where: { $0.id == block }) {
                guard case .code(let oldLanguage, let text) = previous.content, oldLanguage == language else {
                    throw AgentSessionFailure("Code block type or language changed.")
                }

                content = .code(language: language, text: text + delta)
            } else { content = .code(language: language, text: delta) }
        case .toolChanged(let block, let tool):
            id = block
            guard tool.title.utf8.count <= 1024, tool.detail.utf8.count <= 16_000 else {
                throw AgentSessionFailure("Activity output is too large.")
            }

            if let previous = messages[index].blocks.first(where: { $0.id == block }) {
                guard case .tool = previous.content else { throw AgentSessionFailure("Block type changed.") }

                try count(tool.title.utf8.count + tool.detail.utf8.count + 1 - previous.content.plainText.utf8.count)
            } else {
                try count(tool.title.utf8.count + tool.detail.utf8.count + 1)
            }

            content = .tool(tool)
        case .finished: return
        }
        if let blockIndex = messages[index].blocks.firstIndex(where: { $0.id == id }) {
            messages[index].blocks[blockIndex].content = content
            messages[index].blocks[blockIndex].revision &+= 1
        } else {
            guard messages[index].blocks.count < 64 else { throw AgentSessionFailure("Too many response blocks.") }

            messages[index].blocks.append(.init(id: id, content: content))
        }

        changed()
    }

    private func count(_ bytes: Int) throws {
        guard bytes <= 256_000 - replyBytes else { throw AgentSessionFailure("Response limit: 256 KB.") }

        replyBytes += bytes
    }

    private func complete(_ id: UUID) {
        guard activeRequest == id else { return }

        finishResponse(status: .complete)
        activeRequest = nil
        task = nil
        state = .ready
        changed()
    }

    private func finishResponse(status: AgentMessageStatus) {
        guard let index = messages.firstIndex(where: { $0.id == responseID }) else { return }

        messages[index].status = status
        if status == .cancelled || status == .failed {
            for i in messages[index].blocks.indices {
                if case .tool(let tool) = messages[index].blocks[i].content, tool.state == .running {
                    messages[index].blocks[i].content = .tool(.init(
                        title: tool.title,
                        detail: tool.detail,
                        state: .cancelled
                    ))
                    messages[index].blocks[i].revision &+= 1
                }
            }
        }
    }

    public func cancel() {
        guard state == .running, let id = activeRequest else { return }

        state = .cancelling
        task?.cancel()
        changed()
        cancellation = Task { [weak self, provider] in
            await provider.cancel(requestID: id)
            guard let self, activeRequest == id, state == .cancelling else { return }

            finishResponse(status: .cancelled)
            activeRequest = nil
            task = nil
            cancellation = nil
            state = .ready
            changed()
        }
    }

    public func clear() {
        guard canClear else { return }

        messages = []
        contexts = []
        draft = ""
        inputError = nil
        state = .ready
        changed()
    }

    public func stop() {
        guard state != .stopped else { return }

        let id = activeRequest
        activeRequest = nil
        task?.cancel()
        cancellation?.cancel()
        state = .stopped
        if id != nil { finishResponse(status: .cancelled) }
        changed()
        if let id { Task { [provider] in await provider.cancel(requestID: id) } }
    }

    @discardableResult
    public func subscribe(_ observer: @escaping () -> Void) -> UUID {
        let id = UUID()
        observers[id] = observer

        return id
    }

    public func unsubscribe(_ id: UUID) { observers[id] = nil }

    private func changed() { for observer in Array(observers.values) { observer() } }
}

private struct AgentSessionFailure: LocalizedError {
    let reason: String

    init(_ reason: String) { self.reason = reason }

    var errorDescription: String? { reason }
}
