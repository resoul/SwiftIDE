import Foundation
import IDEApplication

public final class ManualDelayClock: DelayClock, @unchecked Sendable {
    private struct Sleeper {
        let id: UInt64
        let deadline: Duration
        let continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private var current: Duration = .zero
    private var sleepers: [Sleeper] = []
    private var nextID: UInt64 = 0

    public init() {}

    public var now: Duration { lock.withLock { current } }
    public var sleeperCount: Int { lock.withLock { sleepers.count } }

    public func sleep(for duration: Duration) async throws {
        let id = lock.withLock { () -> UInt64 in nextID += 1; return nextID }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let cancelledAlready = lock.withLock { () -> Bool in
                    if Task.isCancelled { return true }
                    sleepers.append(Sleeper(id: id, deadline: current + duration, continuation: continuation))

                    return false
                }
                if cancelledAlready { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let sleeper = lock.withLock { () -> Sleeper? in
                guard let index = sleepers.firstIndex(where: { $0.id == id }) else { return nil }

                return sleepers.remove(at: index)
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    public func advance(by duration: Duration) {
        let due = lock.withLock { () -> [Sleeper] in
            current += duration
            let ready = sleepers.filter { $0.deadline <= current }
            sleepers.removeAll { $0.deadline <= current }

            return ready
        }
        for sleeper in due { sleeper.continuation.resume() }
    }
}
