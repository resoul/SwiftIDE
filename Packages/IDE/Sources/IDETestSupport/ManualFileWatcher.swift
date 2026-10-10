import Foundation
import IDEApplication

public final class ManualFileWatcher: FileWatching, @unchecked Sendable {
    private final class Watch: FileWatchHandle, @unchecked Sendable {
        let path: String
        let onEvent: @Sendable () -> Void
        private let lock = NSLock()
        private var isCancelled = false

        init(path: String, onEvent: @escaping @Sendable () -> Void) {
            self.path = path
            self.onEvent = onEvent
        }

        var cancelled: Bool { lock.withLock { isCancelled } }
        func cancel() { lock.withLock { isCancelled = true } }
    }

    private let lock = NSLock()
    private var watches: [Watch] = []

    public init() {}

    public func watch(path: String, onEvent: @escaping @Sendable () -> Void) -> any FileWatchHandle {
        let watch = Watch(path: path, onEvent: onEvent)
        lock.withLock { watches.append(watch) }
        return watch
    }

    public var watchedPaths: [String] {
        lock.withLock { watches.filter { !$0.cancelled }.map(\.path) }
    }

    public func fire(_ path: String) {
        let live = lock.withLock { watches.filter { !$0.cancelled && $0.path == path } }
        for watch in live { watch.onEvent() }
    }
}
