import LocalKit

public struct Core: Sendable {
    public init() {}

    public func message() -> String {
        shout("core")
    }
}
