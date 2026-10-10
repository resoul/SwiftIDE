struct Greeter: Sendable {
    let name: String

    func greeting() -> String {
        "Hello, \(name)!"
    }
}
