/// Tells that something may have happened to a file. It does not say what: events can come in
/// bunches, late, or for nothing, and the one who listens looks at the file itself.
public protocol FileWatching: Sendable {
    /// Starts watching `path` and the place it lives in, so that a file replaced by another one, or
    /// deleted and made again, is noticed too. `onEvent` may be called from any thread.
    func watch(path: String, onEvent: @escaping @Sendable () -> Void) -> any FileWatchHandle
}

public protocol FileWatchHandle: Sendable {
    /// Idempotent. No event is delivered after it returns.
    func cancel()
}
