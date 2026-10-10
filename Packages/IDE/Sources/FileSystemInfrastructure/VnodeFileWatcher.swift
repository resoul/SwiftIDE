import Darwin
import Dispatch
import Foundation
import IDEApplication

/// Watches a file with kernel vnode events on the file and on the directory it is in (ADR-017).
///
/// The file alone is not enough: a program that saves by writing a new file and renaming it over
/// the old one leaves the descriptor on the old, now unlinked, file, and every later change is
/// invisible. So an event that says the file was deleted or renamed, and a change of what the
/// directory holds at that name, re-open the file. The directory's events are for every name in
/// it, so they count only when what is at this name actually changed; a busy directory does not
/// wake the document.
///
/// An event means "look": events can come in bunches, late, and for a change that is already gone.
public struct VnodeFileWatcher: FileWatching {
    public init() {}

    public func watch(path: String, onEvent: @escaping @Sendable () -> Void) -> any FileWatchHandle {
        VnodeWatch(path: path, onEvent: onEvent)
    }
}

private final class VnodeWatch: FileWatchHandle, @unchecked Sendable {
    private struct Snapshot: Equatable {
        var device: Int32
        var inode: UInt64
        var size: Int64
        var modification: Int64
    }

    private let path: String
    private let directoryPath: String
    private let onEvent: @Sendable () -> Void
    private let queue = DispatchQueue(label: "SwiftIDE.VnodeFileWatcher")
    // Everything below is touched on `queue` only.
    private var fileSource: DispatchSourceFileSystemObject?
    private var directorySource: DispatchSourceFileSystemObject?
    private var watchedInode: UInt64?
    private var lastSeen: Snapshot?
    private var isCancelled = false

    init(path: String, onEvent: @escaping @Sendable () -> Void) {
        self.path = path
        self.directoryPath = (path as NSString).deletingLastPathComponent
        self.onEvent = onEvent
        queue.async { [self] in
            lastSeen = snapshot()
            armDirectory()
            armFile()
        }
    }

    deinit {
        isCancelled = true
        fileSource?.cancel()
        directorySource?.cancel()
    }

    func cancel() {
        queue.sync {
            isCancelled = true
            fileSource?.cancel()
            fileSource = nil
            directorySource?.cancel()
            directorySource = nil
        }
    }

    private func snapshot() -> Snapshot? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return Snapshot(
            device: info.st_dev, inode: UInt64(info.st_ino), size: Int64(info.st_size),
            modification: Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
        )
    }

    private func armFile() {
        fileSource?.cancel()
        fileSource = nil
        watchedInode = nil
        let fd = open(path, O_EVTONLY | O_CLOEXEC)
        guard fd >= 0 else { return }   // not there: the directory's events will say when it is
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            close(fd)
            return
        }
        watchedInode = UInt64(info.st_ino)
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .attrib, .delete, .rename, .revoke, .link], queue: queue
        )
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source, !isCancelled else { return }
            let flags = source.data
            lastSeen = snapshot()
            onEvent()
            // The file this descriptor holds is gone from its name: see what is at the name now.
            if !flags.isDisjoint(with: [.delete, .rename, .revoke]) { armFile() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        fileSource = source
    }

    private func armDirectory() {
        let fd = open(directoryPath, O_EVTONLY | O_CLOEXEC)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write], queue: queue)
        source.setEventHandler { [weak self] in
            guard let self, !isCancelled else { return }
            let now = snapshot()
            if now != lastSeen {
                lastSeen = now
                onEvent()
            }
            // A different file is at the name (replaced, or made again): hold that one.
            if let now, now.inode != watchedInode { armFile() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        directorySource = source
    }
}
