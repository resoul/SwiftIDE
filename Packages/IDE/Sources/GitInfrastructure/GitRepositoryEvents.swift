import Foundation
import CoreServices
import IDEApplication

/// Recursive, coalesced disk notifications without recursively enumerating any folder.
public final class GitRepositoryEvents: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let lock = NSLock()
    public var isActive: Bool { lock.withLock { stream != nil } }
    private final class Callback: Sendable {
        let invoke: @Sendable () -> Void

        init(_ invoke: @escaping @Sendable () -> Void) { self.invoke = invoke }
    }

    public init(repository: GitRepository, onChange: @escaping @Sendable () -> Void) {
        let callback = Callback(onChange)
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(callback).toOpaque(),
            retain: { info in
                guard let info else { return nil }

                return UnsafeRawPointer(Unmanaged<Callback>.fromOpaque(info).retain().toOpaque())
            },
            release: { info in
                if let info { Unmanaged<Callback>.fromOpaque(info).release() }
            },
            copyDescription: nil
        )
        let paths = Array(Set([repository.root, repository.gitDirectory, repository.commonDirectory]))
        stream = FSEventStreamCreate(
            nil,
            { _, info, _, _, _, _ in
                guard let info else { return }

                Unmanaged<Callback>.fromOpaque(info).takeUnretainedValue().invoke()
            },
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer |
                kFSEventStreamCreateFlagWatchRoot)
        )
        if let stream {
            FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
            if !FSEventStreamStart(stream) {
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
                self.stream = nil
            }
        }
    }

    /// Called by the owner on the delivery queue before releasing this object.
    public func stop() {
        let current = lock.withLock {
            let current = stream
            stream = nil

            return current
        }
        if let stream = current {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    deinit { stop() }
}
