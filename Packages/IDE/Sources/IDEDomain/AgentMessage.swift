import Foundation

public struct AgentContext: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let documentID: DocumentID
    public let path: String
    public let version: UInt64
    public let range: UTF16TextRange
    public let text: String

    public init(
        id: UUID = UUID(),
        documentID: DocumentID,
        path: String,
        version: UInt64,
        range: UTF16TextRange,
        text: String
    ) {
        self.id = id
        self.documentID = documentID
        self.path = path
        self.version = version
        self.range = range
        self.text = text
    }

    public var name: String { (path as NSString).lastPathComponent }
}

public enum AgentRole: Sendable { case user, assistant }
public enum AgentMessageStatus: Sendable { case streaming, complete, cancelled, failed }
public enum AgentToolState: String, Sendable { case running, succeeded, failed, cancelled }

public struct AgentTool: Equatable, Sendable {
    public let title: String
    public let detail: String
    public let state: AgentToolState

    public init(title: String, detail: String, state: AgentToolState) {
        self.title = title
        self.detail = detail
        self.state = state
    }
}

public enum AgentContent: Equatable, Sendable {
    case text(String)
    case code(language: String, text: String)
    case tool(AgentTool)

    public var plainText: String {
        switch self {
        case .text(let text), .code(_, let text): text
        case .tool(let tool): tool.title + "\n" + tool.detail
        }
    }
}

public struct AgentBlock: Equatable, Sendable, Identifiable {
    public let id: UUID
    public var content: AgentContent
    public var revision: UInt64

    public init(id: UUID = UUID(), content: AgentContent, revision: UInt64 = 0) {
        self.id = id
        self.content = content
        self.revision = revision
    }
}

public struct AgentMessage: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let role: AgentRole
    public var blocks: [AgentBlock]
    public var status: AgentMessageStatus
    public let contexts: [AgentContext]

    public init(
        id: UUID = UUID(),
        role: AgentRole,
        blocks: [AgentBlock],
        status: AgentMessageStatus = .complete,
        contexts: [AgentContext] = []
    ) {
        self.id = id
        self.role = role
        self.blocks = blocks
        self.status = status
        self.contexts = contexts
    }

    public var plainText: String { blocks.map { $0.content.plainText }.joined(separator: "\n\n") }
}

public enum AgentEvent: Equatable, Sendable {
    case textDelta(block: UUID, text: String)
    case codeDelta(block: UUID, language: String, text: String)
    case toolChanged(block: UUID, tool: AgentTool)
    case finished
}

public struct AgentRequest: Equatable, Sendable {
    public let id: UUID
    public let prompt: String
    public let contexts: [AgentContext]

    public init(id: UUID = UUID(), prompt: String, contexts: [AgentContext]) {
        self.id = id
        self.prompt = prompt
        self.contexts = contexts
    }
}
