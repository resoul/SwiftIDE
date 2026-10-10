import Foundation
import IDEApplication
import IDEDomain
import IDETestSupport
import Testing

/// An in-memory file store the test can look through: it counts observations, can change the file
/// between two of them, can type into the document while a file is being read, and can refuse
/// to read.
private struct Store: DocumentFileStore {
    final class Hooks: @unchecked Sendable {
        private let lock = NSLock()
        private var observationCount = 0
        var afterObservation: (@Sendable (Int) async -> Void)?
        var whileReading: (@Sendable () async -> Void)?
        var readFailure: FileStoreError?
        var observationFailure: FileStoreError?

        var observations: Int { lock.withLock { observationCount } }
        func noteObservation() -> Int { lock.withLock { observationCount += 1; return observationCount } }
    }

    let base: MemoryDocumentFileStore
    let hooks = Hooks()

    func read(path: String, maximumBytes: Int) async throws -> LoadedFile {
        await hooks.whileReading?()
        if let failure = hooks.readFailure { throw failure }

        return try await base.read(path: path, maximumBytes: maximumBytes)
    }

    func write(_ snapshot: DocumentSnapshot, expecting: SaveExpectation) async throws -> FileRevision {
        try await base.write(snapshot, expecting: expecting)
    }

    func currentRevision(path: String, assumingUnchangedFrom known: FileRevision?) async throws -> FileRevision? {
        if let failure = hooks.observationFailure { throw failure }
        let revision = try await base.currentRevision(path: path, assumingUnchangedFrom: known)
        let count = hooks.noteObservation()
        await hooks.afterObservation?(count)

        return revision
    }
}

@MainActor
private struct Setup {
    let path: String
    let store: Store
    let registry = DocumentRegistry()
    let session: DocumentSession
    let watcher = ManualFileWatcher()
    let clock = ManualDelayClock()
    let monitor: ExternalChangeMonitor

    init(path: String = "/w/Main.swift", text: String = "let a = 1\n") async throws {
        self.path = path
        store = Store(base: MemoryDocumentFileStore(contents: [path: text]))
        let store = store
        let open = OpenDocumentUseCase(store: store, registry: registry) { file in
            DocumentSession(loaded: file, backend: StringDocumentBackend(loadedText: file.text))
        }
        session = try await open.execute(path: path).session
        monitor = ExternalChangeMonitor(
            session: session,
            files: store,
            watcher: watcher,
            reload: ReloadDocumentUseCase(store: store),
            clock: clock
        )
    }

    func edit(_ text: String) throws {
        try session.apply(
            [DocumentEdit(range: UTF16TextRange(location: 0, length: 0), replacement: text)],
            expectedVersion: session.version
        )
    }

    func writeOutside(_ text: String) async { await store.base.externallyWrite(text, at: path) }

    /// Lets the debounce and the settling waits pass, and the work they start finish.
    func run() async {
        for _ in 0..<40 {
            for _ in 0..<20 { await Task.yield() }
            if clock.sleeperCount > 0 {
                clock.advance(by: .milliseconds(400))
            } else if !monitor.isBusy {
                break
            }
        }
        await monitor.waitUntilIdle()
    }

    func fireAndRun() async {
        watcher.fire(path)
        await run()
    }
}

// MARK: What is not a change

@Test @MainActor
func aDocumentOfOneFileIsWatchedAtItsPath() async throws {
    let s = try await Setup()
    #expect(s.watcher.watchedPaths == ["/w/Main.swift"])
}

@Test @MainActor
func theDocumentsOwnSaveIsNotAnExternalChange() async throws {
    let s = try await Setup()
    try s.edit("// mine\n")
    _ = try await SaveDocumentUseCase(store: s.store).execute(document: s.session)
    await s.fireAndRun()
    #expect(s.monitor.state == .none)
    #expect(s.session.text == "// mine\nlet a = 1\n", "nothing was reloaded over it")
}

@Test @MainActor
func aTouchOrAnIdenticalRewriteIsNotAChange() async throws {
    let s = try await Setup()
    await s.writeOutside("let a = 1\n")   // same bytes, new modification time
    await s.fireAndRun()
    #expect(s.monitor.state == .none && s.session.version == 0)
}

// MARK: A clean document follows the file

@Test @MainActor
func aCleanDocumentIsReloadedWhenTheFileChanges() async throws {
    let s = try await Setup()
    await s.writeOutside("let a = 2\n")
    await s.fireAndRun()
    #expect(s.session.text == "let a = 2\n")
    #expect(!s.session.isDirty, "it is the file's text now")
    #expect(s.monitor.state == .reloaded)
}

@Test @MainActor
func theReloadedNoticeStaysThroughTheEventsThatFollowIt() async throws {
    let s = try await Setup()
    await s.writeOutside("let a = 2\n")
    await s.fireAndRun()
    #expect(s.monitor.state == .reloaded)
    await s.fireAndRun()   // the writer's last events: the document already matches the file
    #expect(s.monitor.state == .reloaded, "information stays until the user dismisses it")
    s.monitor.dismiss()
    #expect(s.monitor.state == .none)
}

@Test @MainActor
func theReloadIsAnOrdinaryEditSoItCanBeUndone() async throws {
    let s = try await Setup()
    var changes: [DocumentChangeSet] = []
    s.session.subscribeToChanges { changes.append($0) }
    await s.writeOutside("let a = 2\n")
    await s.fireAndRun()
    #expect(changes.count == 1 && changes[0].edits.first?.replacement == "let a = 2\n", "published like any edit")
}

@Test @MainActor
func aFileThatChangesAgainWhileItIsBeingWrittenIsReadOnceItHasSettled() async throws {
    let s = try await Setup()
    s.store.hooks.afterObservation = { [store = s.store, path = s.path] count in
        if count == 1 { await store.base.externallyWrite("let a = 3 // second half\n", at: path) }
    }
    await s.writeOutside("let a = 3\n")
    await s.fireAndRun()
    #expect(s.session.text == "let a = 3 // second half\n", "not the half-written first look")
    #expect(s.store.hooks.observations >= 3, "looked again after the file changed, and once more to be sure")
}

@Test @MainActor
func manyEventsInABurstAreOneLook() async throws {
    let s = try await Setup()
    await s.writeOutside("let a = 2\n")
    for _ in 0..<20 { s.watcher.fire(s.path) }
    await s.run()
    #expect(s.store.hooks.observations <= 2, "twenty events, not twenty reads: \(s.store.hooks.observations)")
    #expect(s.session.text == "let a = 2\n")
}

// MARK: A document with unsaved changes is not touched

@Test @MainActor
func aDocumentWithUnsavedChangesIsLeftAloneAndTheUserIsTold() async throws {
    let s = try await Setup()
    try s.edit("// mine\n")
    await s.writeOutside("let a = 2\n")
    await s.fireAndRun()
    #expect(s.monitor.state == .changedWhileEdited)
    #expect(s.session.text == "// mine\nlet a = 1\n")
}

@Test @MainActor
func reloadingFromTheNoticeReplacesTheTextWithTheFile() async throws {
    let s = try await Setup()
    try s.edit("// mine\n")
    await s.writeOutside("let a = 2\n")
    await s.fireAndRun()

    try await s.monitor.reload()
    #expect(s.session.text == "let a = 2\n" && !s.session.isDirty)
    #expect(s.monitor.state == .none)
}

@Test @MainActor
func keepingMineSilencesThatVersionOfTheFileButNotALaterOne() async throws {
    let s = try await Setup()
    try s.edit("// mine\n")
    await s.writeOutside("let a = 2\n")
    await s.fireAndRun()
    s.monitor.keepMine()
    #expect(s.monitor.state == .none)

    await s.fireAndRun()   // the same file again: no new question
    #expect(s.monitor.state == .none)

    await s.writeOutside("let a = 3\n")   // a different change is a new question
    await s.fireAndRun()
    #expect(s.monitor.state == .changedWhileEdited)
}

@Test @MainActor
func keepingMineStillLeavesTheConflictForTheSave() async throws {
    let s = try await Setup()
    try s.edit("// mine\n")
    await s.writeOutside("let a = 2\n")
    await s.fireAndRun()
    s.monitor.keepMine()
    await #expect(throws: FileStoreError.self) {
        _ = try await SaveDocumentUseCase(store: s.store).execute(document: s.session)
    }
}

@Test @MainActor
func textTypedWhileTheFileIsBeingReloadedTurnsTheReloadIntoANotice() async throws {
    let s = try await Setup()
    let session = s.session
    s.store.hooks.whileReading = {
        await MainActor.run {
            try? session.apply(
                [DocumentEdit(range: UTF16TextRange(location: 0, length: 0), replacement: "typed ")],
                expectedVersion: session.version
            )
        }
    }
    await s.writeOutside("let a = 2\n")
    await s.fireAndRun()
    #expect(s.monitor.state == .changedWhileEdited, "the user's keystrokes were not overwritten")
    #expect(s.session.text == "typed let a = 1\n")
}

@Test @MainActor
func savingAfterAConflictNoticeSettlesIt() async throws {
    let s = try await Setup()
    try s.edit("// mine\n")
    await s.writeOutside("let a = 2\n")
    await s.fireAndRun()
    #expect(s.monitor.state == .changedWhileEdited)

    _ = try await SaveDocumentUseCase(store: s.store).execute(document: s.session, overwritingExternalChanges: true)
    await s.run()
    #expect(s.monitor.state == .none, "the file is the document's now")
}

// MARK: Deleted, moved, unreadable

@Test @MainActor
func aDeletedFileIsReportedAndTheDocumentStaysOpen() async throws {
    let s = try await Setup()
    await s.store.base.remove(s.path)
    await s.fireAndRun()
    #expect(s.monitor.state == .removed)
    #expect(s.session.text == "let a = 1\n")
}

@Test @MainActor
func aFileThatComesBackAsItWasClearsTheNotice() async throws {
    let s = try await Setup()
    await s.store.base.remove(s.path)
    await s.fireAndRun()
    #expect(s.monitor.state == .removed)

    await s.writeOutside("let a = 1\n")
    await s.fireAndRun()
    #expect(s.monitor.state == .none)
}

@Test @MainActor
func aFileThatIsMissingOnlyForAMomentIsNotReported() async throws {
    // An editor that saves by deleting and creating leaves the name empty for an instant.
    let s = try await Setup()
    await s.store.base.remove(s.path)
    s.store.hooks.afterObservation = { [store = s.store, path = s.path] count in
        if count == 1 { await store.base.externallyWrite("let a = 1 // saved by another editor\n", at: path) }
    }
    await s.fireAndRun()
    #expect(s.monitor.state == .reloaded, "it was there again by the second look")
    #expect(s.session.text == "let a = 1 // saved by another editor\n")
}

@Test @MainActor
func dismissingANoticeStaysQuietUntilSomethingElseHappens() async throws {
    let s = try await Setup()
    await s.store.base.remove(s.path)
    await s.fireAndRun()
    s.monitor.dismiss()
    #expect(s.monitor.state == .none)

    await s.fireAndRun()
    #expect(s.monitor.state == .none, "the same deleted file is not announced again")

    await s.writeOutside("let a = 9\n")
    await s.fireAndRun()
    #expect(s.monitor.state == .reloaded, "a different thing happened")
}

@Test @MainActor
func aChangeThatCannotBeReadIsReportedWithItsReason() async throws {
    let s = try await Setup()
    s.store.hooks.readFailure = .binary
    await s.writeOutside("let a = 2\n")
    await s.fireAndRun()
    #expect(s.monitor.state == .unreadable(.binary))
    #expect(s.session.text == "let a = 1\n")
}

@Test @MainActor
func somethingThatIsNotAFileIsReportedAsUnreadable() async throws {
    let s = try await Setup()
    s.store.hooks.observationFailure = .notRegularFile
    await s.fireAndRun()
    #expect(s.monitor.state == .unreadable(.notRegularFile))
}

// MARK: Following the document

@Test @MainActor
func saveAsMovesTheWatchToTheNewName() async throws {
    let s = try await Setup(path: "/w/Old.swift")
    #expect(s.watcher.watchedPaths == ["/w/Old.swift"])
    _ = try await SaveDocumentUseCase(store: s.store).saveAs(
        document: s.session,
        to: "/w/New.swift",
        target: .newFile,
        registry: s.registry
    )
    await s.run()
    #expect(s.watcher.watchedPaths == ["/w/New.swift"], "the old name is no longer watched")
}

@Test @MainActor
func aDocumentWithoutAFileIsWatchedOnceItIsSaved() async throws {
    let store = Store(base: MemoryDocumentFileStore())
    let session = DocumentSession(path: "Untitled.swift", backend: StringDocumentBackend(loadedText: "x"), isUntitled: true)
    let watcher = ManualFileWatcher()
    let clock = ManualDelayClock()
    let monitor = ExternalChangeMonitor(
        session: session,
        files: store,
        watcher: watcher,
        reload: ReloadDocumentUseCase(store: store),
        clock: clock
    )
    #expect(watcher.watchedPaths.isEmpty, "there is no file to watch")

    _ = try await SaveDocumentUseCase(store: store).saveAs(
        document: session,
        to: "/w/Fresh.swift",
        target: .newFile,
        registry: DocumentRegistry()
    )
    for _ in 0..<20 { await Task.yield() }
    #expect(watcher.watchedPaths == ["/w/Fresh.swift"])
    _ = monitor
}

@Test @MainActor
func stoppingCancelsTheWatchAndIgnoresLateEvents() async throws {
    let s = try await Setup()
    s.monitor.stop()
    #expect(s.watcher.watchedPaths.isEmpty)
    await s.writeOutside("let a = 2\n")
    await s.fireAndRun()
    #expect(s.session.text == "let a = 1\n" && s.monitor.state == .none)
}

@Test @MainActor
func aMonitorThatWasReleasedWatchesNothingMore() async throws {
    let store = Store(base: MemoryDocumentFileStore(contents: ["/w/A.swift": "a"]))
    let registry = DocumentRegistry()
    let open = OpenDocumentUseCase(store: store, registry: registry) { file in
        DocumentSession(loaded: file, backend: StringDocumentBackend(loadedText: file.text))
    }
    let session = try await open.execute(path: "/w/A.swift").session
    let watcher = ManualFileWatcher()
    var monitor: ExternalChangeMonitor? = ExternalChangeMonitor(
        session: session,
        files: store,
        watcher: watcher,
        reload: ReloadDocumentUseCase(store: store),
        clock: ManualDelayClock()
    )
    #expect(watcher.watchedPaths == ["/w/A.swift"])
    monitor = nil
    #expect(watcher.watchedPaths.isEmpty)
    _ = monitor
}

@Test @MainActor
func aSaveAsWhileTheChangedFileIsBeingReadDropsThatReloadQuietly() async throws {
    let s = try await Setup()
    let session = s.session, store = s.store, registry = s.registry
    s.store.hooks.whileReading = {
        _ = try? await Task { @MainActor in
            try await SaveDocumentUseCase(store: store).saveAs(
                document: session,
                to: "/w/Renamed.swift",
                target: .newFile,
                registry: registry
            )
        }.value
    }
    await s.writeOutside("let a = 2\n")
    await s.fireAndRun()
    #expect(s.session.path == "/w/Renamed.swift")
    #expect(s.session.text == "let a = 1\n", "the old file's text was not poured into the moved document")
    #expect(s.monitor.state == .none, "nothing to tell the user: the document has left that file")
}
