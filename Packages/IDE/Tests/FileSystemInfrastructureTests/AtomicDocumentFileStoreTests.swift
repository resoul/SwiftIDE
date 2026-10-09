import Darwin
import Foundation
import FileSystemInfrastructure
import IDEApplication
import IDEDomain
import Testing

/// Real files in a private temporary directory, removed afterwards.
private final class Sandbox {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftide-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    func path(_ name: String) -> String { directory.appendingPathComponent(name).path }

    @discardableResult
    func create(_ name: String, bytes: [UInt8]) throws -> String {
        let path = path(name)
        try Data(bytes).write(to: URL(fileURLWithPath: path))
        return path
    }

    @discardableResult
    func create(_ name: String, text: String) throws -> String {
        try create(name, bytes: Array(text.utf8))
    }

    func bytes(_ name: String) throws -> [UInt8] {
        [UInt8](try Data(contentsOf: URL(fileURLWithPath: path(name))))
    }

    var entries: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
    }
}

private let store = AtomicDocumentFileStore()

private func snapshot(_ path: String, _ text: String, encoding: FileEncoding = .utf8) -> DocumentSnapshot {
    DocumentSnapshot(documentID: DocumentID(), path: path, version: 1, text: text, encoding: encoding)
}

// MARK: Reading

@Test
func readsUTF8WithoutAlteringLineEndings() async throws {
    let box = try Sandbox()
    let path = try box.create("Mixed.swift", bytes: Array("a\r\nb\nc\rd".utf8))
    let file = try await store.read(path: path, maximumBytes: 1_000)
    #expect(Array(file.text.utf8) == Array("a\r\nb\nc\rd".utf8))
    #expect(file.encoding == .utf8)
    #expect(file.path == path)
}

@Test
func readsAndSavesBOMAndKeepsBytesIdentical() async throws {
    let box = try Sandbox()
    let original: [UInt8] = [0xEF, 0xBB, 0xBF] + Array("let x = 1\r\n".utf8)
    let path = try box.create("Bom.swift", bytes: original)
    let file = try await store.read(path: path, maximumBytes: 1_000)
    #expect(file.encoding == .utf8WithBOM)
    #expect(file.text == "let x = 1\r\n")
    _ = try await store.write(snapshot(path, file.text, encoding: file.encoding), expecting: .revision(file.revision))
    #expect(try box.bytes("Bom.swift") == original)
}

@Test
func emptyFileIsValidText() async throws {
    let box = try Sandbox()
    let path = try box.create("Empty.swift", bytes: [])
    let file = try await store.read(path: path, maximumBytes: 10)
    #expect(file.text.isEmpty)
    #expect(file.revision.size == 0)
}

@Test
func invalidUTF8IsRefusedNotRepaired() async throws {
    let box = try Sandbox()
    let path = try box.create("Bad.swift", bytes: [0x61, 0xC3, 0x28, 0x62])
    await #expect(throws: FileStoreError.notUTF8) { try await store.read(path: path, maximumBytes: 100) }
}

@Test
func binaryIsDetectedByContentNotExtension() async throws {
    let box = try Sandbox()
    let path = try box.create("Looks.swift", bytes: Array("valid utf8".utf8) + [0x00] + Array("more".utf8))
    await #expect(throws: FileStoreError.binary) { try await store.read(path: path, maximumBytes: 100) }
}

@Test
func utf16TextIsReportedAsUnsupportedNotBinary() async throws {
    let box = try Sandbox()
    let path = try box.create("Wide.txt", bytes: [0xFF, 0xFE, 0x61, 0x00, 0x62, 0x00])
    await #expect(throws: FileStoreError.unsupportedEncoding) { try await store.read(path: path, maximumBytes: 100) }
}

@Test
func oversizedMissingAndNonRegularFilesAreRefused() async throws {
    let box = try Sandbox()
    let big = try box.create("Big.swift", bytes: [UInt8](repeating: 0x61, count: 2_000))
    await #expect(throws: FileStoreError.tooLarge(size: 2_000, limit: 1_000)) {
        try await store.read(path: big, maximumBytes: 1_000)
    }
    await #expect(throws: FileStoreError.notFound) { try await store.read(path: box.path("Nope.swift"), maximumBytes: 10) }
    await #expect(throws: FileStoreError.notRegularFile) { try await store.read(path: box.directory.path, maximumBytes: 10) }
}

// MARK: Writing and revisions

@Test
func writtenRevisionEqualsWhatTheNextReadSees() async throws {
    let box = try Sandbox()
    let path = try box.create("Main.swift", text: "old")
    let file = try await store.read(path: path, maximumBytes: 100)
    let written = try await store.write(snapshot(path, "new text"), expecting: .revision(file.revision))
    let reread = try await store.read(path: path, maximumBytes: 100)
    #expect(reread.text == "new text")
    #expect(reread.revision == written)
    // A chain of saves never conflicts with itself.
    let second = try await store.write(snapshot(path, "newer"), expecting: .revision(written))
    #expect(try box.bytes("Main.swift") == Array("newer".utf8))
    #expect(second != written)
}

@Test
func externalChangeAfterReadIsAConflictAndNothingIsWritten() async throws {
    let box = try Sandbox()
    let path = try box.create("Main.swift", text: "original")
    let file = try await store.read(path: path, maximumBytes: 100)
    try box.create("Main.swift", text: "changed by someone else")

    do {
        _ = try await store.write(snapshot(path, "mine"), expecting: .revision(file.revision))
        Issue.record("Expected conflict")
    } catch FileStoreError.conflict(let current) {
        #expect(current?.size == UInt64("changed by someone else".utf8.count))
    }
    #expect(try box.bytes("Main.swift") == Array("changed by someone else".utf8))
    #expect(box.entries == ["Main.swift"], "no temporary file left behind")
}

@Test
func touchOnlyOrIdenticalRewriteIsNotAConflict() async throws {
    let box = try Sandbox()
    let path = try box.create("Main.swift", text: "same bytes")
    let file = try await store.read(path: path, maximumBytes: 100)
    // Same bytes, new modification time (and a new inode, as many editors replace files).
    try await Task.sleep(for: .milliseconds(20))
    try box.create("Main.swift", text: "same bytes")
    let replacement = Data("same bytes".utf8)
    let temp = box.path(".other-editor-temp")
    try replacement.write(to: URL(fileURLWithPath: temp))
    #expect(rename(temp, path) == 0)

    _ = try await store.write(snapshot(path, "edited"), expecting: .revision(file.revision))
    #expect(try box.bytes("Main.swift") == Array("edited".utf8))
}

@Test
func overwriteReplacesAnExternallyChangedFileOnlyWhenAsked() async throws {
    let box = try Sandbox()
    let path = try box.create("Main.swift", text: "original")
    let file = try await store.read(path: path, maximumBytes: 100)
    try box.create("Main.swift", text: "theirs")
    await #expect(throws: (any Error).self) {
        try await store.write(snapshot(path, "mine"), expecting: .revision(file.revision))
    }
    _ = try await store.write(snapshot(path, "mine"), expecting: .overwrite)
    #expect(try box.bytes("Main.swift") == Array("mine".utf8))
}

@Test
func newFileMustNotExistAndDeletedFileIsAConflict() async throws {
    let box = try Sandbox()
    let fresh = box.path("Fresh.swift")
    let created = try await store.write(snapshot(fresh, "hello"), expecting: .revision(nil))
    #expect(created.size == 5)
    #expect(try box.bytes("Fresh.swift") == Array("hello".utf8))
    // The file now exists: creating it again is a conflict.
    await #expect(throws: (any Error).self) { try await store.write(snapshot(fresh, "x"), expecting: .revision(nil)) }

    let path = try box.create("Gone.swift", text: "text")
    let file = try await store.read(path: path, maximumBytes: 100)
    try FileManager.default.removeItem(atPath: path)
    await #expect(throws: FileStoreError.conflict(current: nil)) {
        try await store.write(snapshot(path, "x"), expecting: .revision(file.revision))
    }
    #expect(!FileManager.default.fileExists(atPath: path))
}

@Test
func missingDirectoryIsReportedAndNoFileAppears() async throws {
    let box = try Sandbox()
    let path = box.path("no-such-dir/Main.swift")
    await #expect(throws: FileStoreError.notFound) { try await store.write(snapshot(path, "x"), expecting: .revision(nil)) }
    #expect(box.entries.isEmpty)
}

// MARK: Metadata and links

@Test
func permissionsAndExtendedAttributesSurviveSaving() async throws {
    let box = try Sandbox()
    let path = try box.create("script.swift", text: "#!/usr/bin/env swift\n")
    #expect(chmod(path, 0o755) == 0)
    let value = Array("kept".utf8)
    #expect(setxattr(path, "com.swiftide.test", value, value.count, 0, 0) == 0)
    let file = try await store.read(path: path, maximumBytes: 100)

    _ = try await store.write(snapshot(path, "#!/usr/bin/env swift\nprint(1)\n"), expecting: .revision(file.revision))

    var info = stat()
    #expect(stat(path, &info) == 0)
    #expect(info.st_mode & 0o7777 == 0o755)
    var buffer = [UInt8](repeating: 0, count: 16)
    let length = getxattr(path, "com.swiftide.test", &buffer, buffer.count, 0, 0)
    #expect(length == value.count)
    #expect(Array(buffer.prefix(max(length, 0))) == value)
}

@Test
func savingThroughASymlinkWritesTheTargetAndKeepsTheLink() async throws {
    let box = try Sandbox()
    let target = try box.create("Real.swift", text: "target")
    let link = box.path("Link.swift")
    try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)

    let file = try await store.read(path: link, maximumBytes: 100)
    _ = try await store.write(snapshot(link, "through link"), expecting: .revision(file.revision))

    #expect(try box.bytes("Real.swift") == Array("through link".utf8))
    let destination = try FileManager.default.destinationOfSymbolicLink(atPath: link)
    #expect(destination == target)
    #expect(box.entries == ["Link.swift", "Real.swift"])
}

@Test
func readOnlyFileIsNotReplaced() async throws {
    let box = try Sandbox()
    let path = try box.create("Locked.swift", text: "locked")
    #expect(chmod(path, 0o444) == 0)
    let file = try await store.read(path: path, maximumBytes: 100)
    await #expect(throws: FileStoreError.permissionDenied) {
        try await store.write(snapshot(path, "x"), expecting: .revision(file.revision))
    }
    #expect(try box.bytes("Locked.swift") == Array("locked".utf8))
    #expect(box.entries == ["Locked.swift"])
}

@Test
func pathsWithSpacesAndNonASCIIWork() async throws {
    let box = try Sandbox()
    let path = try box.create("Мой файл 😀.swift", text: "привет")
    let file = try await store.read(path: path, maximumBytes: 100)
    #expect(file.text == "привет")
    _ = try await store.write(snapshot(path, "пока"), expecting: .revision(file.revision))
    #expect(try box.bytes("Мой файл 😀.swift") == Array("пока".utf8))
}

@Test
func largeFileRoundTripsExactly() async throws {
    let box = try Sandbox()
    let line = "let value = \"юникод 😀\" // padding padding padding\r\n"
    let text = String(repeating: line, count: 80_000)   // ≈ 5 MB
    let path = try box.create("Large.swift", text: text)
    let file = try await store.read(path: path, maximumBytes: 50_000_000)
    #expect(Array(file.text.utf8) == Array(text.utf8))
    _ = try await store.write(snapshot(path, file.text), expecting: .revision(file.revision))
    #expect(try box.bytes("Large.swift") == Array(text.utf8))
}

// MARK: Review regressions

@Test
func sameSizeSameMtimeSameInodeContentChangeIsStillAConflict() async throws {
    let box = try Sandbox()
    let path = try box.create("Main.swift", text: "AAAA")
    let file = try await store.read(path: path, maximumBytes: 100)
    var original = stat()
    #expect(stat(path, &original) == 0)

    // Another program rewrites the bytes in place and puts the timestamps back.
    let handle = try #require(FileHandle(forWritingAtPath: path))
    try handle.write(contentsOf: Data("BBBB".utf8))
    try handle.close()
    let times = [original.st_atimespec, original.st_mtimespec]
    #expect(utimensat(AT_FDCWD, path, times, 0) == 0)
    var now = stat()
    #expect(stat(path, &now) == 0)
    #expect(now.st_ino == original.st_ino && now.st_size == original.st_size)
    #expect(now.st_mtimespec.tv_nsec == original.st_mtimespec.tv_nsec)

    do {
        _ = try await store.write(snapshot(path, "mine"), expecting: .revision(file.revision))
        Issue.record("Expected conflict")
    } catch FileStoreError.conflict {
    }
    #expect(try box.bytes("Main.swift") == Array("BBBB".utf8))
}

@Test
func failedMetadataTransferAbortsTheSaveBeforeTheOriginalIsTouched() async throws {
    let box = try Sandbox()
    let path = try box.create("Main.swift", text: "original")
    let file = try await store.read(path: path, maximumBytes: 100)
    var original = stat()
    #expect(stat(path, &original) == 0)

    let failing = AtomicDocumentFileStore(metadataTransfer: MetadataTransfer { _, _, _ in
        throw FileStoreError.cannotPreserveMetadata(code: ENOTSUP)
    })
    await #expect(throws: FileStoreError.cannotPreserveMetadata(code: ENOTSUP)) {
        try await failing.write(snapshot(path, "new"), expecting: .revision(file.revision))
    }
    var after = stat()
    #expect(stat(path, &after) == 0)
    #expect(after.st_ino == original.st_ino, "the original file was not replaced")
    #expect(try box.bytes("Main.swift") == Array("original".utf8))
    #expect(box.entries == ["Main.swift"], "no temporary file left behind")
}

@Test
func accessControlListsSurviveSaving() async throws {
    let box = try Sandbox()
    let path = try box.create("Acl.swift", text: "text")
    let chmod = Process()
    chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
    chmod.arguments = ["+a", "everyone allow read", path]
    try chmod.run()
    chmod.waitUntilExit()
    try #require(chmod.terminationStatus == 0, "could not set an ACL in this environment")
    func hasACL() -> Bool {
        guard let acl = acl_get_file(path, ACL_TYPE_EXTENDED) else { return false }
        acl_free(UnsafeMutableRawPointer(acl))
        return true
    }
    #expect(hasACL())
    let file = try await store.read(path: path, maximumBytes: 100)
    _ = try await store.write(snapshot(path, "changed"), expecting: .revision(file.revision))
    #expect(try box.bytes("Acl.swift") == Array("changed".utf8))
    #expect(hasACL(), "the ACL of the replaced file carried over")
}

@Test
func hardLinksAreNotClaimedToSurviveAnAtomicSave() async throws {
    // Documents the policy: an atomic save gives the file a new inode; the other link keeps the old.
    let box = try Sandbox()
    let first = try box.create("First.swift", text: "shared")
    let second = box.path("Second.swift")
    #expect(link(first, second) == 0)
    let file = try await store.read(path: first, maximumBytes: 100)
    _ = try await store.write(snapshot(first, "edited"), expecting: .revision(file.revision))
    #expect(try box.bytes("First.swift") == Array("edited".utf8))
    #expect(try box.bytes("Second.swift") == Array("shared".utf8))
}
