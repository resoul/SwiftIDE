import Foundation
import FileSystemInfrastructure
import IDEApplication
import IDEDomain
import IDETestSupport
import Testing

/// Real files and a real journal, with a "crash" in between: everything of the first run is thrown
/// away without a clean shutdown, and a second run starts from what is on disk.
@MainActor
private final class Run {
    let files = AtomicDocumentFileStore()
    let registry = DocumentRegistry()
    let journal: RecoveryJournal
    let open: OpenDocumentUseCase
    var restorer: RecoveryRestorer!

    init(journalDirectory: URL) {
        journal = RecoveryJournal(directory: journalDirectory)
        open = OpenDocumentUseCase(store: files, registry: registry) { file in
            DocumentSession(loaded: file, backend: StringDocumentBackend(loadedText: file.text))
        }
        restorer = RecoveryRestorer(store: journal, files: files, open: open) { _ in
            DocumentSession(path: "Untitled.swift", backend: StringDocumentBackend(loadedText: ""), isUntitled: true)
        }
    }
}

private final class Disk {
    let directory: URL
    var journalDirectory: URL { directory.appendingPathComponent("Recovery", isDirectory: true) }

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftide-e2e-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    func file(_ name: String, _ text: String) throws -> String {
        let path = directory.appendingPathComponent(name).path
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    func text(_ path: String) throws -> String { try String(contentsOfFile: path, encoding: .utf8) }
}

@Test @MainActor
func unsavedTextSurvivesACrashAndComesBackOnTheNextRun() async throws {
    let disk = try Disk()
    let path = try disk.file("Main.swift", "let a = 1\n")

    // First run: edit, and the app is lost (the background flush ran; nothing else did).
    do {
        let run = Run(journalDirectory: disk.journalDirectory)
        let session = try await run.open.execute(path: path).session
        let coordinator = RecoveryCoordinator(session: session, store: run.journal)
        try session.apply(
            [DocumentEdit(range: UTF16TextRange(location: 10, length: 0), replacement: "let b = 2 // поток 😀\n")],
            expectedVersion: session.version
        )
        await coordinator.flush()
        // No discard, no save: the process is gone.
    }
    #expect(try disk.text(path) == "let a = 1\n", "the file was never touched")

    // Second run.
    let run = Run(journalDirectory: disk.journalDirectory)
    let scan = try await run.restorer.scan()
    let candidate = try #require(scan.candidates.first)
    #expect(scan.candidates.count == 1 && candidate.disk == .unchanged && scan.unreadable.isEmpty)

    let restored = try await run.restorer.restore(candidate)
    let session = try #require(restored.session)
    #expect(session.text == "let a = 1\nlet b = 2 // поток 😀\n" && session.isDirty)

    // Once it is saved there is nothing left to recover.
    let coordinator = RecoveryCoordinator(session: session, store: run.journal)
    await coordinator.flush()
    _ = try await SaveDocumentUseCase(store: run.files).execute(document: session)
    await coordinator.waitUntilIdle()
    #expect(try disk.text(path) == "let a = 1\nlet b = 2 // поток 😀\n")
    #expect(try await run.journal.pending().records.isEmpty)
}

@Test @MainActor
func aFileChangedBetweenTheCrashAndTheRestoreIsNotOverwrittenBySaving() async throws {
    let disk = try Disk()
    let path = try disk.file("Main.swift", "base\n")
    do {
        let run = Run(journalDirectory: disk.journalDirectory)
        let session = try await run.open.execute(path: path).session
        let coordinator = RecoveryCoordinator(session: session, store: run.journal)
        try session.replaceText("base\nmine\n", expectedVersion: session.version)
        await coordinator.flush()
    }
    try "base\nsomeone else\n".write(toFile: path, atomically: true, encoding: .utf8)

    let run = Run(journalDirectory: disk.journalDirectory)
    let candidate = try #require(try await run.restorer.scan().candidates.first)
    #expect(candidate.disk == .changed)
    let session = try #require(try await run.restorer.restore(candidate).session)
    #expect(session.text == "base\nmine\n")

    await #expect(throws: FileStoreError.self) { _ = try await SaveDocumentUseCase(store: run.files).execute(document: session) }
    #expect(try disk.text(path) == "base\nsomeone else\n", "nothing was overwritten")
}

@Test @MainActor
func aSavedDocumentAndAQuitThatDiscardedLeaveNothingToRecover() async throws {
    let disk = try Disk()
    let saved = try disk.file("Saved.swift", "a\n")
    let dropped = try disk.file("Dropped.swift", "b\n")
    let run = Run(journalDirectory: disk.journalDirectory)

    let first = try await run.open.execute(path: saved).session
    let firstCoordinator = RecoveryCoordinator(session: first, store: run.journal)
    try first.replaceText("a2\n", expectedVersion: first.version)
    await firstCoordinator.flush()
    #expect(try await run.journal.pending().records.count == 1)
    _ = try await SaveDocumentUseCase(store: run.files).execute(document: first)
    await firstCoordinator.waitUntilIdle()

    let second = try await run.open.execute(path: dropped).session
    let secondCoordinator = RecoveryCoordinator(session: second, store: run.journal)
    try second.replaceText("b2\n", expectedVersion: second.version)
    await secondCoordinator.flush()
    await secondCoordinator.discard()   // quit with Don't Save

    #expect(try await run.journal.pending().records.isEmpty)
}
