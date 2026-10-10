import Darwin
import Foundation
import FileSystemInfrastructure
import IDEApplication
import IDEDomain
import Testing

/// Real files in a private directory. Events come from the kernel, so waits are generous and a
/// test that expects silence waits a while to make sure it was not just slow.
private final class Sandbox {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftide-watch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    func path(_ name: String) -> String { directory.appendingPathComponent(name).path }

    func create(_ name: String, _ text: String = "start\n") throws -> String {
        try text.write(toFile: path(name), atomically: false, encoding: .utf8)

        return path(name)
    }

    func append(_ name: String, _ text: String) throws {
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path(name)))
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    /// What another editor does: a new file under a temporary name, then renamed over the old one.
    func replaceAtomically(_ name: String, _ text: String) throws {
        let temporary = path(".\(name).tmp")
        try text.write(toFile: temporary, atomically: false, encoding: .utf8)
        guard rename(temporary, path(name)) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func bump() { lock.withLock { value += 1 } }

    /// Waits for at least one event more than `since`; false if none came.
    func eventually(after since: Int, seconds: Double = 5) async -> Bool {
        let clock = SuspendingClock()
        let deadline = clock.now.advanced(by: .seconds(seconds))
        while clock.now < deadline {
            if count > since { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }

        return false
    }
}

private func watching(_ path: String) -> (any FileWatchHandle, Counter) {
    let counter = Counter()
    let handle = VnodeFileWatcher().watch(path: path) { counter.bump() }

    return (handle, counter)
}

/// The watch arms itself on its own queue; give it a moment before the first change.
private func armed() async { try? await Task.sleep(for: .milliseconds(150)) }

@Test
func aChangeInPlaceIsNoticed() async throws {
    let sandbox = try Sandbox()
    let path = try sandbox.create("a.swift")
    let (handle, events) = watching(path)
    defer { handle.cancel() }
    await armed()
    try sandbox.append("a.swift", "more\n")
    #expect(await events.eventually(after: 0))
}

@Test
func aFileReplacedByAnotherIsNoticedAndSoIsTheNextChangeToTheNewOne() async throws {
    let sandbox = try Sandbox()
    let path = try sandbox.create("a.swift")
    let (handle, events) = watching(path)
    defer { handle.cancel() }
    await armed()

    try sandbox.replaceAtomically("a.swift", "replaced\n")
    #expect(await events.eventually(after: 0), "the replacement")
    try? await Task.sleep(for: .milliseconds(200))

    // The descriptor first opened is on the old, unlinked file. The watch must have moved to the new one.
    let before = events.count
    try sandbox.append("a.swift", "and then edited in place\n")
    #expect(await events.eventually(after: before), "a change to the file that replaced it")
}

@Test
func severalReplacementsInARowLeaveTheWatchWorking() async throws {
    let sandbox = try Sandbox()
    let path = try sandbox.create("a.swift")
    let (handle, events) = watching(path)
    defer { handle.cancel() }
    await armed()
    for round in 0..<15 {
        try sandbox.replaceAtomically("a.swift", "round \(round)\n")
        try? await Task.sleep(for: .milliseconds(40))
    }
    try? await Task.sleep(for: .milliseconds(300))
    let before = events.count
    try sandbox.append("a.swift", "last\n")
    #expect(await events.eventually(after: before), "still watching after fifteen replacements")
}

@Test
func aDeletedFileIsNoticedAndSoIsItsReturn() async throws {
    let sandbox = try Sandbox()
    let path = try sandbox.create("a.swift")
    let (handle, events) = watching(path)
    defer { handle.cancel() }
    await armed()

    try FileManager.default.removeItem(atPath: path)
    #expect(await events.eventually(after: 0), "the deletion")
    try? await Task.sleep(for: .milliseconds(200))

    let afterDelete = events.count
    _ = try sandbox.create("a.swift", "back\n")
    #expect(await events.eventually(after: afterDelete), "the file made again")
    try? await Task.sleep(for: .milliseconds(200))

    let afterReturn = events.count
    try sandbox.append("a.swift", "and changed\n")
    #expect(await events.eventually(after: afterReturn), "and the new file is watched")
}

@Test
func aFileRenamedAwayIsNoticed() async throws {
    let sandbox = try Sandbox()
    let path = try sandbox.create("a.swift")
    let (handle, events) = watching(path)
    defer { handle.cancel() }
    await armed()
    try FileManager.default.moveItem(atPath: path, toPath: sandbox.path("moved.swift"))
    #expect(await events.eventually(after: 0))
}

@Test
func aFileThatDoesNotExistYetIsNoticedWhenItAppears() async throws {
    let sandbox = try Sandbox()
    let (handle, events) = watching(sandbox.path("later.swift"))
    defer { handle.cancel() }
    await armed()
    _ = try sandbox.create("later.swift")
    #expect(await events.eventually(after: 0))
}

@Test
func aTouchIsNoticed() async throws {
    let sandbox = try Sandbox()
    let path = try sandbox.create("a.swift")
    let (handle, events) = watching(path)
    defer { handle.cancel() }
    await armed()
    #expect(utimes(path, nil) == 0)
    #expect(await events.eventually(after: 0), "the monitor decides, by the bytes, that a touch is nothing")
}

@Test
func otherFilesInTheSameDirectoryAreNotAnEvent() async throws {
    let sandbox = try Sandbox()
    let path = try sandbox.create("a.swift")
    let (handle, events) = watching(path)
    defer { handle.cancel() }
    await armed()
    for index in 0..<10 {
        _ = try sandbox.create("noise-\(index).txt")
        try sandbox.append("noise-\(index).txt", "x")
    }
    try? await Task.sleep(for: .milliseconds(700))
    #expect(events.count == 0, "a busy directory must not wake the document: \(events.count) events")
}

@Test
func aCancelledWatchSaysNothingMore() async throws {
    let sandbox = try Sandbox()
    let path = try sandbox.create("a.swift")
    let (handle, events) = watching(path)
    await armed()
    handle.cancel()
    let before = events.count
    try sandbox.append("a.swift", "after cancel\n")
    try sandbox.replaceAtomically("a.swift", "and replaced\n")
    try? await Task.sleep(for: .milliseconds(700))
    #expect(events.count == before)
    handle.cancel()   // idempotent
}

@Test
func theStoresOwnSaveIsAnEventLikeAnyOther() async throws {
    // The monitor, not the watcher, knows it was the document's own save; the watcher just reports.
    let sandbox = try Sandbox()
    let path = try sandbox.create("a.swift")
    let (handle, events) = watching(path)
    defer { handle.cancel() }
    await armed()
    let store = AtomicDocumentFileStore()
    let revision = try await store.read(path: path, maximumBytes: .max).revision
    _ = try await store.write(
        DocumentSnapshot(documentID: DocumentID(), path: path, version: 1, text: "saved\n"),
        expecting: .revision(revision)
    )
    #expect(await events.eventually(after: 0))
}

// MARK: The store's cheap check

@Test
func theCurrentRevisionIsReadOnlyWhenTheFileDiffersFromWhatIsKnown() async throws {
    let sandbox = try Sandbox()
    let path = try sandbox.create("a.swift", "one\n")
    let store = AtomicDocumentFileStore()
    let known = try await store.read(path: path, maximumBytes: .max).revision

    #expect(try await store.currentRevision(path: path, assumingUnchangedFrom: known) == known, "same file: not read again")

    try sandbox.replaceAtomically("a.swift", "two\n")
    let changed = try #require(try await store.currentRevision(path: path, assumingUnchangedFrom: known))
    #expect(!changed.hasSameContent(as: known))

    try FileManager.default.removeItem(atPath: path)
    #expect(try await store.currentRevision(path: path, assumingUnchangedFrom: known) == nil)
}

@Test
func aDirectoryIsNotAFileForTheCurrentRevision() async throws {
    let sandbox = try Sandbox()
    await #expect(throws: FileStoreError.notRegularFile) {
        _ = try await AtomicDocumentFileStore().currentRevision(path: sandbox.directory.path, assumingUnchangedFrom: nil)
    }
}
