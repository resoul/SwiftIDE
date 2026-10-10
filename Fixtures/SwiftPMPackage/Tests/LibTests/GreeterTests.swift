import Testing
@testable import Lib

@Test func greets() {
    #expect(Greeter(name: "a").greeting() == "Hello, a!")
}
