import Darwin
import Foundation
import FileSystemInfrastructure
import IDEApplication
import IDEDomain
import IDETestSupport
import Testing

/// A real file, the real watcher and store, and the real clock with short waits.
@MainActor
private final class Rig {
    let directory: URL
    let path: String
    let store = AtomicDocumentFileStore()
    let registry = DocumentRegistry()
    let session: DocumentSession
    let monitor: ExternalChangeMonitor

    init(text: String = "let a = 1\n") async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftide-ext-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // The temporary directory's own name may be a link: the document uses the real one.
        path = DocumentPath.canonical(directory.appendingPathComponent("Main.swift").path)
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        let store = store
        let open = OpenDocumentUseCase(store: store, registry: registry) { file in
            DocumentSession(loaded: file, backend: StringDocumentBackend(loadedText: file.text))
        }
        session = try await open.execute(path: path).session
        monitor = ExternalChangeMonitor(
            session: session,
            files: store,
            watcher: VnodeFileWatcher(),
            reload: ReloadDocumentUseCase(store: store),
            policy: ExternalChangePolicy(debounce: .milliseconds(80), settle: .milliseconds(80))
        )
        try await Task.sleep(for: .milliseconds(150))   // the watch arms itself
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    func replaceAtomically(_ text: String) throws {
        let temporary = directory.appendingPathComponent(".swap.tmp").path
        try text.write(toFile: temporary, atomically: false, encoding: .utf8)
        guard rename(temporary, path) == 0 else { throw POSIXError(.EIO) }
    }

    func append(_ text: String) throws {
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    func fileText() throws -> String { try String(contentsOfFile: path, encoding: .utf8) }

    /// Waits until `condition` holds; false if it never did.
    func eventually(seconds: Double = 6, _ condition: () -> Bool) async -> Bool {
        let clock = SuspendingClock()
        let deadline = clock.now.advanced(by: .seconds(seconds))
        while clock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }

        return condition()
    }
}

@Test @MainActor
func anotherProgramReplacingTheFileReloadsACleanDocument() async throws {
    let rig = try await Rig()
    try rig.replaceAtomically("let a = 2 // from another editor\n")
    #expect(await rig.eventually { rig.monitor.state == .reloaded })
    #expect(rig.session.text == "let a = 2 // from another editor\n" && !rig.session.isDirty)
}

@Test @MainActor
func anotherProgramAppendingInPlaceReloadsACleanDocument() async throws {
    let rig = try await Rig()
    try rig.append("let b = 2\n")   // what `echo >> file` does
    #expect(await rig.eventually { rig.monitor.state == .reloaded })
    #expect(rig.session.text == "let a = 1\nlet b = 2\n")
}

@Test @MainActor
func twoReplacementsInARowAreBothFollowed() async throws {
    // The watch must move to the file that replaced the first one, or the second change is never seen.
    let rig = try await Rig()
    try rig.replaceAtomically("first\n")
    #expect(await rig.eventually { rig.session.text == "first\n" })
    try? await Task.sleep(for: .milliseconds(300))
    try rig.replaceAtomically("second\n")
    #expect(await rig.eventually { rig.session.text == "second\n" }, "text is \(rig.session.text.debugDescription)")
}

@Test @MainActor
func theDocumentsOwnSaveRaisesNothing() async throws {
    let rig = try await Rig()
    try rig.session.apply(
        [DocumentEdit(range: UTF16TextRange(location: 0, length: 0), replacement: "// mine\n")],
        expectedVersion: 0
    )
    _ = try await SaveDocumentUseCase(store: rig.store).execute(document: rig.session)
    try? await Task.sleep(for: .milliseconds(900))   // the events of the save, looked at and judged
    #expect(rig.monitor.state == .none)
    #expect(rig.session.text == "// mine\nlet a = 1\n" && !rig.session.isDirty)
    #expect(try rig.fileText() == "// mine\nlet a = 1\n")
}

@Test @MainActor
func aDocumentWithUnsavedChangesIsNotReloadedAndStillConflictsOnSave() async throws {
    let rig = try await Rig()
    try rig.session.apply(
        [DocumentEdit(range: UTF16TextRange(location: 0, length: 0), replacement: "// mine\n")],
        expectedVersion: 0
    )
    try rig.replaceAtomically("let a = 'theirs'\n")
    #expect(await rig.eventually { rig.monitor.state == .changedWhileEdited })
    #expect(rig.session.text == "// mine\nlet a = 1\n")

    await #expect(throws: FileStoreError.self) { _ = try await SaveDocumentUseCase(store: rig.store).execute(document: rig.session) }
    #expect(try rig.fileText() == "let a = 'theirs'\n", "their change was not overwritten")

    try await rig.monitor.reload()
    #expect(rig.session.text == "let a = 'theirs'\n" && !rig.session.isDirty)
    #expect(rig.monitor.state == .none)
}

@Test @MainActor
func aDeletedFileIsReportedAndItsReturnWithTheSameTextClearsIt() async throws {
    let rig = try await Rig()
    try FileManager.default.removeItem(atPath: rig.path)
    #expect(await rig.eventually { rig.monitor.state == .removed })

    try "let a = 1\n".write(toFile: rig.path, atomically: true, encoding: .utf8)
    #expect(await rig.eventually { rig.monitor.state == .none })
}

@Test @MainActor
func aTouchChangesNothing() async throws {
    let rig = try await Rig()
    #expect(utimes(rig.path, nil) == 0)
    try? await Task.sleep(for: .milliseconds(800))
    #expect(rig.monitor.state == .none && rig.session.version == 0)
}
