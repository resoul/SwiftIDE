public struct Counter: Sendable {
    public private(set) var value = 0

    public init() {}

    public mutating func increment() {
        value += 1
    }
}
