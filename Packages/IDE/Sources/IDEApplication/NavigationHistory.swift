import Foundation

/// A place in a file, for coming back to it.
public struct NavigationPlace: Equatable, Sendable {
    public let path: String
    /// Zero-based line, and the UTF-16 offset in it, as the language protocol counts them.
    public let line: Int
    public let character: Int

    public init(path: String, line: Int, character: Int) {
        self.path = path
        self.line = line
        self.character = character
    }
}

/// Where the user jumped from, newest last: what "Go Back" returns to.
public struct NavigationHistory: Sendable {
    public static let limit = 100
    public private(set) var places: [NavigationPlace] = []

    public init() {}

    public var canGoBack: Bool { !places.isEmpty }

    /// Remembers a place left behind by a jump. Leaving the same place twice in a row counts once.
    public mutating func push(_ place: NavigationPlace) {
        guard places.last != place else { return }

        places.append(place)
        if places.count > Self.limit { places.removeFirst(places.count - Self.limit) }
    }

    /// The place to go back to, and forget it.
    public mutating func pop() -> NavigationPlace? {
        places.popLast()
    }
}
