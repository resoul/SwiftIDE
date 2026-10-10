import Darwin
import Foundation
import FileSystemInfrastructure
import IDEApplication
import IDEDomain
import Testing

/// A private directory for one test, removed afterwards.
private final class Sandbox {
    let directory: URL
    var journalDirectory: URL { directory.appendingPathComponent("Recovery", isDirectory: true) }

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftide-recovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit {
        // A test may have made a directory unwritable.
        chmod(journalDirectory.path, 0o700)
        try? FileManager.default.removeItem(at: directory)
    }

    var files: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: journalDirectory.path)) ?? []).sorted()
    }

    func permissions(of url: URL) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return ((attributes?[.posixPermissions] as? NSNumber)?.intValue ?? -1) & 0o777
    }
}

private func revision(_ tick: Int64 = 7) -> FileRevision {
    FileRevision(
        fileID: FileIdentity(device: 16_777_231, inode: 9_001), size: 1234, modificationTime: 1_760_000_000_123_456_789 + tick,
        contentDigest: ContentDigest(bytes: (0..<32).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ Int(tick)) })
    )
}

private func record(
    _ key: RecoveryKey = .file(atPath: "/w/Main.swift"), text: String = "let a = 1\n", savedAt: Double = 1_760_000_000.5,
    path: String? = "/w/Main.swift", base: FileRevision? = revision(), encoding: FileEncoding = .utf8
) -> RecoveryRecord {
    RecoveryRecord(
        key: key, path: path, title: path.map { ($0 as NSString).lastPathComponent } ?? "Untitled", text: text,
        encoding: encoding, baseRevision: base, savedAt: Date(timeIntervalSince1970: savedAt)
    )
}

// MARK: Round trip

@Test
func aRecordComesBackExactlyAsItWasWritten() async throws {
    let sandbox = try Sandbox()
    let journal = RecoveryJournal(directory: sandbox.journalDirectory)
    // Everything that could be lost in an encoding: emoji, every kind of line ending, NUL, a BOM flag.
    let text = "α😀\r\nline\rtwo\nnul:\u{0}end \u{FEFF}\n"
    let original = record(text: text, encoding: .utf8WithBOM)
    try await journal.write(original)

    let listing = try await journal.pending()
    #expect(listing.unreadable.isEmpty)
    #expect(listing.records == [original])
}

@Test
func aRecordWithoutAFileOrARevisionComesBackAsSuch() async throws {
    let sandbox = try Sandbox()
    let journal = RecoveryJournal(directory: sandbox.journalDirectory)
    let scratch = record(.scratch(DocumentID()), text: "scratch", path: nil, base: nil)
    try await journal.write(scratch)
    #expect(try await journal.pending().records == [scratch])
}

@Test
func recordsSurviveANewJournalOnTheSameDirectory() async throws {
    // What a restart is: nothing of the first journal is left but the files.
    let sandbox = try Sandbox()
    try await RecoveryJournal(directory: sandbox.journalDirectory).write(record())
    let second = RecoveryJournal(directory: sandbox.journalDirectory)
    #expect(try await second.pending().records == [record()])
}

@Test
func aLargeRecordRoundTrips() async throws {
    let sandbox = try Sandbox()
    let journal = RecoveryJournal(directory: sandbox.journalDirectory)
    let big = String(repeating: "let value = 42 // поток 😀\n", count: 60_000)   // ≈ 2 MB
    try await journal.write(record(text: big))
    #expect(try await journal.pending().records.first?.text == big)
}

// MARK: Replacing, removing, ordering

@Test
func writingAKeyAgainReplacesItAndLeavesOneFile() async throws {
    let sandbox = try Sandbox()
    let journal = RecoveryJournal(directory: sandbox.journalDirectory)
    try await journal.write(record(text: "first"))
    try await journal.write(record(text: "second"))
    #expect(try await journal.pending().records.map(\.text) == ["second"])
    #expect(sandbox.files.count == 1, "no temporary file is left behind: \(sandbox.files)")
}

@Test
func removingDeletesTheRecordAndRemovingNothingIsFine() async throws {
    let sandbox = try Sandbox()
    let journal = RecoveryJournal(directory: sandbox.journalDirectory)
    try await journal.write(record())
    try await journal.remove(.file(atPath: "/w/Main.swift"))
    #expect(try await journal.pending().records.isEmpty)
    try await journal.remove(.file(atPath: "/w/Main.swift"))
    try await RecoveryJournal(directory: sandbox.directory.appendingPathComponent("nothing-here")).remove(.file(atPath: "/x"))
}

@Test
func anEmptyOrMissingDirectoryHasNothingPending() async throws {
    let sandbox = try Sandbox()
    let listing = try await RecoveryJournal(directory: sandbox.journalDirectory).pending()
    #expect(listing == RecoveryListing())
}

@Test
func recordsComeBackOldestFirst() async throws {
    let sandbox = try Sandbox()
    let journal = RecoveryJournal(directory: sandbox.journalDirectory)
    try await journal.write(record(.file(atPath: "/w/B.swift"), text: "b", savedAt: 2_000, path: "/w/B.swift"))
    try await journal.write(record(.file(atPath: "/w/A.swift"), text: "a", savedAt: 3_000, path: "/w/A.swift"))
    try await journal.write(record(.file(atPath: "/w/C.swift"), text: "c", savedAt: 1_000, path: "/w/C.swift"))
    #expect(try await journal.pending().records.map(\.text) == ["c", "b", "a"])
}

@Test
func aKeyCannotMakeAFileOutsideTheDirectory() async throws {
    let sandbox = try Sandbox()
    let journal = RecoveryJournal(directory: sandbox.journalDirectory)
    try await journal.write(record(.file(atPath: "/../../escape/../x"), text: "t"))
    try await journal.write(record(RecoveryKey(rawValue: "file:/a/b\u{0}c"), text: "u"))
    let outside = (try? FileManager.default.contentsOfDirectory(atPath: sandbox.directory.path)) ?? []
    #expect(outside == ["Recovery"], "nothing was created beside the journal directory: \(outside)")
    #expect(sandbox.files.count == 2)
}

// MARK: Privacy

@Test
func theDirectoryAndTheFilesAreReadableOnlyByTheUser() async throws {
    let sandbox = try Sandbox()
    let journal = RecoveryJournal(directory: sandbox.journalDirectory)
    try await journal.write(record())
    #expect(sandbox.permissions(of: sandbox.journalDirectory) == 0o700, "source code is not for other users")
    let file = sandbox.journalDirectory.appendingPathComponent(try #require(sandbox.files.first))
    #expect(sandbox.permissions(of: file) == 0o600)
}

// MARK: Damage

@Test
func aTruncatedRecordIsReportedAndTheOthersAreStillRead() async throws {
    let sandbox = try Sandbox()
    let journal = RecoveryJournal(directory: sandbox.journalDirectory)
    try await journal.write(record(.file(atPath: "/w/Good.swift"), text: "good", path: "/w/Good.swift"))
    try await journal.write(record(.file(atPath: "/w/Cut.swift"), text: String(repeating: "x", count: 5_000), path: "/w/Cut.swift"))
    // Cut the second one short, as a full disk or a crash in the middle of a copy would.
    for name in sandbox.files {
        let url = sandbox.journalDirectory.appendingPathComponent(name)
        let data = try Data(contentsOf: url)
        if data.count > 3_000 { try data.prefix(data.count - 2_000).write(to: url) }
    }
    let listing = try await journal.pending()
    #expect(listing.records.map(\.text) == ["good"])
    #expect(listing.unreadable.count == 1, "damage is reported, not silently skipped")
}

@Test
func aChangedByteInTheTextIsDetected() async throws {
    let sandbox = try Sandbox()
    let journal = RecoveryJournal(directory: sandbox.journalDirectory)
    try await journal.write(record(text: "let answer = 42\n"))
    let url = sandbox.journalDirectory.appendingPathComponent(try #require(sandbox.files.first))
    var data = try Data(contentsOf: url)
    data[data.count - 3] ^= 0x01   // 42 becomes 4;
    try data.write(to: url)
    let listing = try await journal.pending()
    #expect(listing.records.isEmpty && listing.unreadable.count == 1, "a wrong text must not be offered as the user's")
}

@Test
func aFileThatIsNotARecordIsReported() async throws {
    let sandbox = try Sandbox()
    try FileManager.default.createDirectory(at: sandbox.journalDirectory, withIntermediateDirectories: true)
    try Data("garbage".utf8).write(to: sandbox.journalDirectory.appendingPathComponent("0123.recovery"))
    try Data().write(to: sandbox.journalDirectory.appendingPathComponent("empty.recovery"))
    let listing = try await RecoveryJournal(directory: sandbox.journalDirectory).pending()
    #expect(listing.records.isEmpty && listing.unreadable.count == 2)
}

@Test
func temporaryFilesFromACrashedWriteAreNotRecordsAndOldOnesAreCleanedUp() async throws {
    let sandbox = try Sandbox()
    let journal = RecoveryJournal(directory: sandbox.journalDirectory)
    try await journal.write(record())
    let old = sandbox.journalDirectory.appendingPathComponent(".dead.tmp")
    let fresh = sandbox.journalDirectory.appendingPathComponent(".live.tmp")
    try Data("half written".utf8).write(to: old)
    try Data("being written right now".utf8).write(to: fresh)
    let twoMinutesAgo = Date().addingTimeInterval(-120)
    try FileManager.default.setAttributes([.modificationDate: twoMinutesAgo], ofItemAtPath: old.path)

    let listing = try await journal.pending()
    #expect(listing.records == [record()] && listing.unreadable.isEmpty, "a half-written file is not a record")
    #expect(!FileManager.default.fileExists(atPath: old.path), "left by a crash long ago: removed")
    #expect(FileManager.default.fileExists(atPath: fresh.path), "may belong to a write in progress: left alone")
}

@Test
func aFailedWriteLeavesThePreviousRecordAsItWas() async throws {
    let sandbox = try Sandbox()
    let journal = RecoveryJournal(directory: sandbox.journalDirectory)
    try await journal.write(record(text: "kept"))
    chmod(sandbox.journalDirectory.path, 0o500)   // no new files can be made in it
    if getuid() == 0 { return }   // root ignores the mode
    await #expect(throws: (any Error).self) { try await journal.write(record(text: "lost")) }
    chmod(sandbox.journalDirectory.path, 0o700)
    #expect(try await journal.pending().records.map(\.text) == ["kept"])
    #expect(sandbox.files.count == 1, "and no temporary file: \(sandbox.files)")
}

@Test
func writesToDifferentKeysAtTheSameTimeAreAllKept() async throws {
    let sandbox = try Sandbox()
    let journal = RecoveryJournal(directory: sandbox.journalDirectory)
    await withTaskGroup(of: Void.self) { group in
        for index in 0..<20 {
            group.addTask {
                try? await journal.write(record(.file(atPath: "/w/F\(index).swift"), text: "text \(index)", path: "/w/F\(index).swift"))
            }
        }
    }
    #expect(try await journal.pending().records.count == 20)
}
