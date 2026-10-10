public struct Greeter: Sendable {
    public let name: String

    public init(name: String) {
        self.name = name
    }

    public func greeting() -> String {
        "Hello, \(name)!"
    }
}
