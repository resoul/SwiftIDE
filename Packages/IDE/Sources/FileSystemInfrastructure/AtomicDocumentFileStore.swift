import CryptoKit
import Darwin
import Foundation
import IDEApplication
import IDEDomain

/// Reads and writes UTF-8 text files on the local filesystem.
///
/// Saving checks the file against the expected revision and replaces it atomically (temporary
/// file in the same directory, then `rename`), inside an `NSFileCoordinator` write. Limits that
/// are deliberate: coordination only protects against writers that coordinate too, so a plain
/// `write(2)` by another program can still slip in between the check and the rename; and
/// `fsync` of the temporary file does not promise the data survives a power cut.
public struct AtomicDocumentFileStore: DocumentFileStore {
    private let metadataTransfer: MetadataTransfer

    public init(metadataTransfer: MetadataTransfer = .system) {
        self.metadataTransfer = metadataTransfer
    }

    /// The revision of the file at `path` as it is right now, or nil if there is no such file.
    /// Reads the file's bytes, so it is for the moment a user agrees to replace a file, not for
    /// anything frequent. Throws for anything that is not a regular file.
    public static func currentRevision(atPath path: String) throws -> FileRevision? {
        do {
            return try FileReader.revisionOfBytes(at: path)
        } catch FileStoreError.notFound {
            return nil
        }
    }

    public func read(path: String, maximumBytes: Int) async throws -> LoadedFile {
        try Task.checkCancellation()
        return try await Task.detached(priority: .userInitiated) {
            try FileReader.read(path: path, maximumBytes: maximumBytes)
        }.value
    }

    public func write(_ snapshot: DocumentSnapshot, expecting: SaveExpectation) async throws -> FileRevision {
        try Task.checkCancellation()
        let transfer = metadataTransfer
        return try await Task.detached(priority: .userInitiated) {
            try FileWriter.write(snapshot, expecting: expecting, metadataTransfer: transfer)
        }.value
    }
}

/// Carries what makes a file the same file (mode, owner, ACLs, extended attributes) from the
/// file being replaced to its temporary replacement. Any failure aborts the save before the
/// original is touched. Replaceable so the failure path can be tested.
public struct MetadataTransfer: Sendable {
    /// `source` is the file being replaced, `descriptor`/`destination` the open temporary file.
    public let transfer: @Sendable (_ source: String, _ descriptor: Int32, _ destination: String) throws -> Void

    public init(_ transfer: @escaping @Sendable (_ source: String, _ descriptor: Int32, _ destination: String) throws -> Void) {
        self.transfer = transfer
    }

    /// Not preserved, and not claimed: BSD file flags (hidden, immutable), birth time, and hard
    /// links (an atomic replacement gives the file a new inode; other links keep the old one).
    public static let system = MetadataTransfer { source, descriptor, destination in
        var original = stat()
        guard stat(source, &original) == 0 else { throw POSIX.error(errno) }
        func fail() -> FileStoreError { .cannotPreserveMetadata(code: errno) }

        if copyfile(source, destination, nil, copyfile_flags_t(COPYFILE_ACL | COPYFILE_XATTR)) != 0 { throw fail() }
        var replacement = stat()
        guard fstat(descriptor, &replacement) == 0 else { throw fail() }
        // Owner first: changing it clears set-uid/set-gid bits that the mode below restores.
        if replacement.st_uid != original.st_uid || replacement.st_gid != original.st_gid {
            if fchown(descriptor, original.st_uid, original.st_gid) != 0 { throw fail() }
        }
        if fchmod(descriptor, original.st_mode & 0o7777) != 0 { throw fail() }
    }
}

// MARK: - Shared helpers

private enum POSIX {
    static func error(_ code: Int32) -> FileStoreError {
        switch code {
        case ENOENT, ENOTDIR: .notFound
        case EACCES, EPERM, EROFS: .permissionDenied
        default: .io(code: code)
        }
    }

    static func revision(of info: stat, digest: ContentDigest) -> FileRevision {
        FileRevision(
            fileID: FileIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino)),
            size: UInt64(info.st_size),
            modificationTime: Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec),
            contentDigest: digest
        )
    }

    static func digest(of bytes: [UInt8]) -> ContentDigest {
        ContentDigest(bytes: Array(SHA256.hash(data: bytes)))
    }

    static func isRegular(_ info: stat) -> Bool {
        (info.st_mode & S_IFMT) == S_IFREG
    }

    /// Reads at most `limit + 1` bytes so growth beyond the limit is noticed, from an open file.
    static func readAll(fd: Int32, expected: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: expected + 1)
        var total = 0
        while total < bytes.count {
            let count = bytes[total...].withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EINTR { continue }
                throw error(errno)
            }
            if count == 0 { break }
            total += count
        }
        // More bytes than fstat promised: the file grew while it was read.
        guard total == expected else { throw FileStoreError.changedWhileReading }
        bytes.removeLast()
        return bytes
    }

    static func metadataMatches(_ a: stat, _ b: stat) -> Bool {
        a.st_size == b.st_size && a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec
            && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec && a.st_ino == b.st_ino
    }
}

// MARK: - Reading

private enum FileReader {
    static func read(path: String, maximumBytes: Int) throws -> LoadedFile {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw POSIX.error(errno) }
        defer { close(fd) }

        var before = stat()
        guard fstat(fd, &before) == 0 else { throw POSIX.error(errno) }
        guard POSIX.isRegular(before) else { throw FileStoreError.notRegularFile }
        guard before.st_size <= maximumBytes else {
            throw FileStoreError.tooLarge(size: UInt64(before.st_size), limit: maximumBytes)
        }
        let bytes = try POSIX.readAll(fd: fd, expected: Int(before.st_size))
        var after = stat()
        guard fstat(fd, &after) == 0 else { throw POSIX.error(errno) }
        guard POSIX.metadataMatches(before, after) else { throw FileStoreError.changedWhileReading }

        let (text, encoding) = try decode(bytes)
        return LoadedFile(
            path: path, text: text, encoding: encoding,
            revision: POSIX.revision(of: after, digest: POSIX.digest(of: bytes))
        )
    }

    /// Revision of whatever bytes the file holds now, decoded or not: a conflicting file may be
    /// binary or in another encoding and must still be comparable and describable.
    static func revisionOfBytes(at path: String) throws -> FileRevision {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw POSIX.error(errno) }
        defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0 else { throw POSIX.error(errno) }
        guard POSIX.isRegular(before) else { throw FileStoreError.notRegularFile }
        let bytes = try POSIX.readAll(fd: fd, expected: Int(before.st_size))
        var after = stat()
        guard fstat(fd, &after) == 0, POSIX.metadataMatches(before, after) else {
            throw FileStoreError.changedWhileReading
        }
        return POSIX.revision(of: after, digest: POSIX.digest(of: bytes))
    }

    /// Strict UTF-8. Nothing is repaired: a lossy decode followed by a save would corrupt the file.
    static func decode(_ bytes: [UInt8]) throws -> (String, FileEncoding) {
        // UTF-16/32 text is full of NUL bytes; recognise it before calling the file binary.
        if bytes.starts(with: [0xFF, 0xFE]) || bytes.starts(with: [0xFE, 0xFF])
            || bytes.starts(with: [0x00, 0x00, 0xFE, 0xFF]) {
            throw FileStoreError.unsupportedEncoding
        }
        if bytes.contains(0) { throw FileStoreError.binary }
        let hasBOM = bytes.starts(with: [0xEF, 0xBB, 0xBF])
        let body = hasBOM ? bytes.dropFirst(3) : bytes[...]
        guard let text = String(bytes: body, encoding: .utf8) else { throw FileStoreError.notUTF8 }
        return (text, hasBOM ? .utf8WithBOM : .utf8)
    }
}

// MARK: - Writing

private enum FileWriter {
    static func write(
        _ snapshot: DocumentSnapshot, expecting: SaveExpectation, metadataTransfer: MetadataTransfer
    ) throws -> FileRevision {
        // A link is never replaced by a file: the target is what gets written.
        let url = URL(fileURLWithPath: snapshot.path).resolvingSymlinksInPath()
        var outcome: Result<FileRevision, Error> = .failure(FileStoreError.io(code: EINVAL))
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: url, options: .forReplacing, error: &coordinationError
        ) { coordinatedURL in
            outcome = Result {
                try replace(
                    path: coordinatedURL.path, with: snapshot, expecting: expecting,
                    metadataTransfer: metadataTransfer
                )
            }
        }
        if let coordinationError { throw FileStoreError.io(code: Int32(truncatingIfNeeded: coordinationError.code)) }
        return try outcome.get()
    }

    private static func replace(
        path: String, with snapshot: DocumentSnapshot, expecting: SaveExpectation,
        metadataTransfer: MetadataTransfer
    ) throws -> FileRevision {
        var existing = stat()
        let exists = stat(path, &existing) == 0
        if !exists, errno != ENOENT { throw POSIX.error(errno) }
        if exists, !POSIX.isRegular(existing) { throw FileStoreError.notRegularFile }

        if case .revision(let expected) = expecting {
            try verify(expected: expected, path: path, existing: exists ? existing : nil)
        }
        if exists, access(path, W_OK) != 0 { throw FileStoreError.permissionDenied }

        var data = [UInt8]()
        if snapshot.encoding == .utf8WithBOM { data += [0xEF, 0xBB, 0xBF] }
        data += Array(snapshot.text.utf8)

        let directory = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        var template = Array("\(directory)/.\(name).swiftide-XXXXXX".utf8CString)
        let fd = mkstemp(&template)
        guard fd >= 0 else { throw POSIX.error(errno) }
        let temporary = String(decoding: template.dropLast().map { UInt8(bitPattern: $0) }, as: UTF8.self)
        var renamed = false
        defer {
            close(fd)
            if !renamed { unlink(temporary) }
        }

        if exists {
            try metadataTransfer.transfer(path, fd, temporary)
        } else {
            let mask = umask(0)
            umask(mask)
            guard fchmod(fd, 0o666 & ~mask) == 0 else { throw FileStoreError.cannotPreserveMetadata(code: errno) }
        }
        try writeAll(fd: fd, bytes: data)
        guard fsync(fd) == 0 else { throw POSIX.error(errno) }
        guard rename(temporary, path) == 0 else { throw POSIX.error(errno) }
        renamed = true

        var written = stat()
        guard stat(path, &written) == 0 else { throw POSIX.error(errno) }
        return POSIX.revision(of: written, digest: POSIX.digest(of: data))
    }

    /// Decided by the bytes on disk right now, read again for every save: metadata can be put
    /// back by the program that changed the file, so equal size and mtime prove nothing. A file
    /// that was merely touched, or rewritten with identical bytes, is not a conflict.
    private static func verify(expected: FileRevision?, path: String, existing: stat?) throws {
        switch (expected, existing) {
        case (nil, nil):
            return
        case (let expected?, _?):
            let current = try FileReader.revisionOfBytes(at: path)
            if current.hasSameContent(as: expected) { return }
            throw FileStoreError.conflict(current: current)
        case (nil, _?):
            throw FileStoreError.conflict(current: try? FileReader.revisionOfBytes(at: path))
        case (_?, nil):
            throw FileStoreError.conflict(current: nil)
        }
    }

    private static func writeAll(fd: Int32, bytes: [UInt8]) throws {
        var offset = 0
        while offset < bytes.count {
            let count = bytes[offset...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EINTR { continue }
                throw POSIX.error(errno)
            }
            offset += count
        }
    }
}
