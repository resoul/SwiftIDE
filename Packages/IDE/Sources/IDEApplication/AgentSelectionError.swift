import Foundation

public struct AgentSelectionError: LocalizedError, Sendable {
    public let reason: String

    public init(_ reason: String) { self.reason = reason }

    public var errorDescription: String? { reason }
}
