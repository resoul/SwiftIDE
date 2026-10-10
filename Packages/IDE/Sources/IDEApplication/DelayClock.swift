import Foundation

/// A monotonic clock that things which wait (a debounce, a retry) use; a test drives it by hand.
public protocol DelayClock: Sendable {
    /// Time since an arbitrary start; only differences mean anything.
    var now: Duration { get }
    func sleep(for duration: Duration) async throws
}

public struct SystemDelayClock: DelayClock {
    private let origin = ContinuousClock.now

    public init() {}

    public var now: Duration { origin.duration(to: ContinuousClock.now) }

    public func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}
