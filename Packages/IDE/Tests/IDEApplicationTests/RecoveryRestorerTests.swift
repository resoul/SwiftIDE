import Foundation
import IDEApplication
import IDEDomain
import IDETestSupport
import Testing

@MainActor
private struct World {
    let files: MemoryDocumentFileStore
    let recovery = MemoryRecoveryStore()
    let registry = DocumentRegistry()
    let restorer: RecoveryRestorer
    let open: OpenDocumentUseCase

    init(files initial: [String: String] = [:]) {
        let files = MemoryDocumentFileStore(contents: initial)
        self.files = files
        let registry = registry
        open = OpenDocumentUseCase(store: files, registry: registry) { file in
            DocumentSession(loaded: file, backend: StringDocumentBackend(loadedText: file.text))
        }
        restorer = RecoveryRestorer(
            store: recovery, files: files, open: open,
            makeScratch: { title in
                DocumentSession(path: "Untitled.swift", backend: StringDocumentBackend(loadedText: ""), isUntitled: true)
            }
        )
    }

    /// The record a crashed run would have left for a file: its text, based on the file as it is now.
    func leftBehind(_ path: String, text: String, base: String? = nil) async throws -> RecoveryRecord {
        let revision = try await files.read(path: path, maximumBytes: .max).revision
        let record = RecoveryRecord(
            key: .file(atPath: path), path: path, title: (path as NSString).lastPathComponent, text: text,
            encoding: .utf8, baseRevision: revision, savedAt: Date(timeIntervalSince1970: 1_000)
        )
        await recovery.seed(record)
        return record
    }

    func scratchRecord(_ text: String) async -> RecoveryRecord {
        let record = RecoveryRecord(
            key: .scratch(DocumentID()), path: nil, title: "Untitled", text: text, encoding: .utf8,
            baseRevision: nil, savedAt: Date(timeIntervalSince1970: 2_000)
        )
        await recovery.seed(record)
        return record
    }
}

// MARK: Looking at what was left

@Test @MainActor
func theScanSaysWhatBecameOfEachFile() async throws {
    let w = World(files: ["/w/Same.swift": "same", "/w/Moved.swift": "before", "/w/Gone.swift": "gone"])
    _ = try await w.leftBehind("/w/Same.swift", text: "same + edits")
    _ = try await w.leftBehind("/w/Moved.swift", text: "mine")
    _ = try await w.leftBehind("/w/Gone.swift", text: "mine too")
    _ = await w.scratchRecord("scratch text")
    await w.files.externallyWrite("someone else's", at: "/w/Moved.swift")
    await w.files.remove("/w/Gone.swift")

    let scan = try await w.restorer.scan()
    let states = Dictionary(uniqueKeysWithValues: scan.candidates.map { ($0.record.title, $0.disk) })
    #expect(states == ["Same.swift": .unchanged, "Moved.swift": .changed, "Gone.swift": .missing, "Untitled": .notApplicable])
}

@Test @MainActor
func theScanPassesOnWhatCouldNotBeRead() async throws {
    let w = World()
    await w.recovery.setUnreadable(["abc.recovery: the record is cut short"])
    let scan = try await w.restorer.scan()
    #expect(scan.candidates.isEmpty)
    #expect(scan.unreadable == ["abc.recovery: the record is cut short"])
}

// MARK: Restoring

@Test @MainActor
func aRecoveredFileOpensWithItsTextAsUnsavedChanges() async throws {
    let w = World(files: ["/w/Main.swift": "let a = 1\n"])
    let record = try await w.leftBehind("/w/Main.swift", text: "let a = 1\nlet b = 2\n")
    let candidate = RecoveryCandidate(record: record, disk: .unchanged)

    let restored = try await w.restorer.restore(candidate)
    let session = try #require(restored.session)
    #expect(restored.outcome == .restored && restored.isNew)
    #expect(session.path == "/w/Main.swift" && !session.isUntitled)
    #expect(session.text == "let a = 1\nlet b = 2\n")
    #expect(session.isDirty, "it is unsaved: the file still holds the old text")
    #expect(await w.files.text(at: "/w/Main.swift") == "let a = 1\n", "restoring writes nothing to disk")

    // And saving it works like saving any edit.
    _ = try await SaveDocumentUseCase(store: w.files).execute(document: session)
    #expect(await w.files.text(at: "/w/Main.swift") == "let a = 1\nlet b = 2\n")
}

@Test @MainActor
func aFileThatChangedOnDiskStillConflictsWhenTheRecoveredTextIsSaved() async throws {
    let w = World(files: ["/w/Main.swift": "base\n"])
    let record = try await w.leftBehind("/w/Main.swift", text: "base\nmy edit\n")
    await w.files.externallyWrite("base\nsomeone else's edit\n", at: "/w/Main.swift")
    let candidate = RecoveryCandidate(record: record, disk: .changed)

    let session = try #require(try await w.restorer.restore(candidate).session)
    #expect(session.text == "base\nmy edit\n")

    // The text was based on the old file; saving it must not silently replace the newer one.
    let save = SaveDocumentUseCase(store: w.files)
    await #expect(throws: FileStoreError.self) { _ = try await save.execute(document: session) }
    #expect(await w.files.text(at: "/w/Main.swift") == "base\nsomeone else's edit\n", "the other change is untouched")

    // Replacing it is possible, but only as the user's explicit choice.
    _ = try await save.execute(document: session, overwritingExternalChanges: true)
    #expect(await w.files.text(at: "/w/Main.swift") == "base\nmy edit\n")
}

@Test @MainActor
func aRecoveredFileThatNoLongerExistsOpensAsAnUntitledDocument() async throws {
    let w = World(files: ["/w/Gone.swift": "x"])
    let record = try await w.leftBehind("/w/Gone.swift", text: "x + mine")
    await w.files.remove("/w/Gone.swift")

    let restored = try await w.restorer.restore(RecoveryCandidate(record: record, disk: .missing))
    let session = try #require(restored.session)
    #expect(restored.outcome == .restoredAsScratch)
    #expect(session.isUntitled && session.text == "x + mine" && session.isDirty)
}

@Test @MainActor
func aRecoveredDocumentThatNeverHadAFileOpensAsAnUntitledDocument() async throws {
    let w = World()
    let record = await w.scratchRecord("let draft = 1\n")
    let restored = try await w.restorer.restore(RecoveryCandidate(record: record, disk: .notApplicable))
    let session = try #require(restored.session)
    #expect(restored.outcome == .restoredAsScratch && session.isUntitled)
    #expect(session.text == "let draft = 1\n" && session.isDirty)
}

@Test @MainActor
func aRecordThatEqualsTheFileHasNothingToRestore() async throws {
    let w = World(files: ["/w/Main.swift": "same\n"])
    let record = try await w.leftBehind("/w/Main.swift", text: "same\n")
    let restored = try await w.restorer.restore(RecoveryCandidate(record: record, disk: .unchanged))
    #expect(restored.session == nil && restored.outcome == .nothingToRestore)
}

@Test @MainActor
func aFileAlreadyOpenWithUnsavedChangesIsLeftAlone() async throws {
    let w = World(files: ["/w/Main.swift": "disk\n"])
    let record = try await w.leftBehind("/w/Main.swift", text: "recovered\n")
    let existing = try await w.open.execute(path: "/w/Main.swift").session
    try existing.replaceText("typed since launch\n", expectedVersion: 0)

    let restored = try await w.restorer.restore(RecoveryCandidate(record: record, disk: .unchanged))
    #expect(restored.outcome == .alreadyOpenAndModified && restored.session == nil)
    #expect(existing.text == "typed since launch\n", "newer work is not overwritten by older work")
}

@Test @MainActor
func discardingACandidateRemovesItsRecord() async throws {
    let w = World(files: ["/w/Main.swift": "a"])
    let record = try await w.leftBehind("/w/Main.swift", text: "b")
    try await w.restorer.discard(RecoveryCandidate(record: record, disk: .unchanged))
    #expect(await w.recovery.keys.isEmpty)
}

@Test @MainActor
func theOriginalRecordIsKeptWhenItIsTheOneTheNewDocumentWillOverwrite() async throws {
    let w = World(files: ["/w/Main.swift": "a"])
    let record = try await w.leftBehind("/w/Main.swift", text: "b")
    // The restored document writes under the same key, so removing the record would leave a
    // window in which a crash loses the recovered text.
    try await w.restorer.discard(RecoveryCandidate(record: record, disk: .unchanged), unlessKept: record.key)
    #expect(await w.recovery.keys == [record.key])

    try await w.restorer.discard(RecoveryCandidate(record: record, disk: .unchanged), unlessKept: .file(atPath: "/other"))
    #expect(await w.recovery.keys.isEmpty)
}

// MARK: The file changes between the scan and the restore

@Test @MainActor
func aFileChangedAfterTheScanStillConflictsWhenTheRecoveredTextIsSaved() async throws {
    let w = World(files: ["/w/Main.swift": "base\n"])
    let record = try await w.leftBehind("/w/Main.swift", text: "base\nmy edit\n")
    // The scan found the file as it was kept ...
    let scanned = RecoveryCandidate(record: record, disk: .unchanged)
    // ... then another program wrote it while the question was on screen.
    await w.files.externallyWrite("base\nsomeone else's edit\n", at: "/w/Main.swift")

    let session = try #require(try await w.restorer.restore(scanned).session)
    let save = SaveDocumentUseCase(store: w.files)
    await #expect(throws: FileStoreError.self) { _ = try await save.execute(document: session) }
    #expect(await w.files.text(at: "/w/Main.swift") == "base\nsomeone else's edit\n", "the other change is untouched")
}

// MARK: Letting go of the old record

@Test @MainActor
func theOldRecordGoesOnlyOnceTheNewOneIsConfirmed() async throws {
    let w = World(files: ["/w/Gone.swift": "x"])
    let record = try await w.leftBehind("/w/Gone.swift", text: "x + mine")
    await w.files.remove("/w/Gone.swift")
    let candidate = RecoveryCandidate(record: record, disk: .missing)
    let session = try #require(try await w.restorer.restore(candidate).session)   // untitled: a new key
    #expect(session.recoveryKey != record.key)

    let clock = ManualDelayClock()
    let coordinator = RecoveryCoordinator(session: session, store: w.recovery, clock: clock)

    // The new copy cannot be written: the old one is all there is.
    await w.recovery.setFailingWrites(true)
    let first = try await w.restorer.retire(candidate, restoredAs: session) { await coordinator.flush() }
    #expect(first == false)
    #expect(await w.recovery.keys == [record.key], "the only copy is still there")

    // Written now: the old one may go.
    await w.recovery.setFailingWrites(false)
    let second = try await w.restorer.retire(candidate, restoredAs: session) { await coordinator.flush() }
    #expect(second)
    #expect(await w.recovery.keys == [session.recoveryKey])
}

@Test @MainActor
func theOldRecordStaysWhenTheNewDocumentIsTooLargeToKeep() async throws {
    let w = World(files: ["/w/Gone.swift": "x"])
    let record = try await w.leftBehind("/w/Gone.swift", text: "x + mine, and rather long")
    await w.files.remove("/w/Gone.swift")
    let candidate = RecoveryCandidate(record: record, disk: .missing)
    let session = try #require(try await w.restorer.restore(candidate).session)
    let coordinator = RecoveryCoordinator(
        session: session, store: w.recovery,
        policy: RecoveryPolicy(debounce: .seconds(2), maximumDelay: .seconds(10), maximumUTF16Length: 5),
        clock: ManualDelayClock()
    )
    let retired = try await w.restorer.retire(candidate, restoredAs: session) { await coordinator.flush() }
    #expect(retired == false)
    #expect(await w.recovery.keys == [record.key])
}

@Test @MainActor
func aRecordThatTheNewDocumentOverwritesIsNeverRemovedByRetiring() async throws {
    let w = World(files: ["/w/Main.swift": "a"])
    let record = try await w.leftBehind("/w/Main.swift", text: "b")
    let candidate = RecoveryCandidate(record: record, disk: .unchanged)
    let session = try #require(try await w.restorer.restore(candidate).session)
    #expect(session.recoveryKey == record.key)
    let retired = try await w.restorer.retire(candidate, restoredAs: session) { .nothingUnsaved }
    #expect(retired == false)
    #expect(await w.recovery.keys == [record.key])
}

@Test @MainActor
func aReceiptOlderThanTheRestoredTextDoesNotRetireTheOldRecord() async throws {
    let w = World(files: ["/w/Gone.swift": "x"])
    let record = try await w.leftBehind("/w/Gone.swift", text: "x + mine")
    await w.files.remove("/w/Gone.swift")
    let candidate = RecoveryCandidate(record: record, disk: .missing)
    let session = try #require(try await w.restorer.restore(candidate).session)
    let stale = Safekeeping.written(session.recoveryKey, version: session.version - 1)
    #expect(try await w.restorer.retire(candidate, restoredAs: session) { stale } == false)
    #expect(await w.recovery.keys == [record.key])

    let current = Safekeeping.written(session.recoveryKey, version: session.version)
    #expect(try await w.restorer.retire(candidate, restoredAs: session) { current })
    #expect(await w.recovery.keys.isEmpty)
}
