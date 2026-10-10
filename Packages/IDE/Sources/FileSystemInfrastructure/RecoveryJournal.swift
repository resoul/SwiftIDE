import CryptoKit
import Darwin
import Foundation
import IDEApplication
import IDEDomain

/// Unsaved documents on disk, one file per document, in a directory of their own (ADR-016).
///
/// A record is a magic line, a one-line JSON header (the key, the path, what the text was based
/// on, its length and SHA-256) and the text itself as UTF-8. Reading checks all of it, so a file
/// that was cut short or changed is reported and never offered as the user's text. Writing goes
/// through a temporary file in the same directory and a `rename`, so a record is either the old
/// one or the new one. Files are named by a hash of the key, which keeps any key, whatever
/// characters it holds, inside the directory. The directory and its files are private to the user.
///
/// `fsync` of the temporary file does not promise the data survives a power cut.
public struct RecoveryJournal: RecoveryStore {
    private static let magic = "SWIFTIDE-RECOVERY 1"
    private static let suffix = ".recovery"
    /// A temporary file this old belongs to a write that died; a younger one may be in use.
    private static let staleTemporaryAge: TimeInterval = 60

    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public func write(_ record: RecoveryRecord) async throws {
        try Self.makeDirectory(directory)
        try Self.writeFile(record, directory: directory)
    }

    public func remove(_ key: RecoveryKey) async throws {
        let path = directory.appendingPathComponent(Self.fileName(for: key)).path
        if unlink(path) != 0, errno != ENOENT { throw POSIX.error(errno) }
    }

    public func pending() async throws -> RecoveryListing {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return RecoveryListing()
        }

        var listing = RecoveryListing()
        for name in names.sorted() {
            let url = directory.appendingPathComponent(name)
            if name.hasPrefix("."), name.hasSuffix(".tmp") {
                Self.removeIfStale(url)
                continue
            }

            guard name.hasSuffix(Self.suffix) else { continue }

            do {
                listing.records.append(try Self.read(url))
            } catch {
                listing.unreadable.append("\(name): \(error)")
            }
        }
        listing.records.sort { ($0.savedAt, $0.key.rawValue) < ($1.savedAt, $1.key.rawValue) }

        return listing
    }

    // MARK: Format

    private struct Header: Codable {
        struct Base: Codable {
            var device: UInt64
            var inode: UInt64
            var size: UInt64
            var modificationTime: Int64
            var digest: String
        }

        var key: String
        var path: String?
        var title: String
        var encoding: String
        var base: Base?
        var savedAt: Double
        var bytes: Int
        var sha256: String
    }

    private enum Damage: Error, CustomStringConvertible {
        case notARecord, truncated, wrongDigest, badHeader(String)

        var description: String {
            switch self {
            case .notARecord: "not a recovery record"
            case .truncated: "the record is cut short"
            case .wrongDigest: "the text does not match its checksum"
            case .badHeader(let reason): "unreadable header (\(reason))"
            }
        }
    }

    private static func hex(_ bytes: some Sequence<UInt8>) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func fileName(for key: RecoveryKey) -> String {
        hex(SHA256.hash(data: Array(key.rawValue.utf8)).prefix(16)) + suffix
    }

    private static func encode(_ record: RecoveryRecord) throws -> [UInt8] {
        let text = Array(record.text.utf8)
        let base = record.baseRevision.map {
            Header.Base(
                device: $0.fileID.device,
                inode: $0.fileID.inode,
                size: $0.size,
                modificationTime: $0.modificationTime,
                digest: hex($0.contentDigest.bytes)
            )
        }
        let header = Header(
            key: record.key.rawValue,
            path: record.path,
            title: record.title,
            encoding: record.encoding == .utf8WithBOM ? "utf8BOM" : "utf8",
            base: base,
            savedAt: record.savedAt.timeIntervalSince1970,
            bytes: text.count,
            sha256: hex(SHA256.hash(data: text))
        )
        var out = Array((magic + "\n").utf8)
        out += try JSONEncoder().encode(header)
        out.append(0x0A)
        out += text

        return out
    }

    private static func read(_ url: URL) throws -> RecoveryRecord {
        let data = [UInt8](try Data(contentsOf: url))
        guard let firstBreak = data.firstIndex(of: 0x0A),
              String(decoding: data[..<firstBreak], as: UTF8.self) == magic else { throw Damage.notARecord }

        guard let secondBreak = data[(firstBreak + 1)...].firstIndex(of: 0x0A) else { throw Damage.truncated }

        let header: Header
        do {
            header = try JSONDecoder().decode(Header.self, from: Data(data[(firstBreak + 1)..<secondBreak]))
        } catch {
            throw Damage.badHeader("\(error)")
        }
        let text = Array(data[(secondBreak + 1)...])
        guard text.count == header.bytes else { throw Damage.truncated }

        guard hex(SHA256.hash(data: text)) == header.sha256 else { throw Damage.wrongDigest }

        guard let string = String(bytes: text, encoding: .utf8) else { throw Damage.wrongDigest }

        var base: FileRevision?
        if let b = header.base {
            guard let digest = bytes(fromHex: b.digest) else { throw Damage.badHeader("revision digest") }

            base = FileRevision(
                fileID: FileIdentity(device: b.device, inode: b.inode),
                size: b.size,
                modificationTime: b.modificationTime,
                contentDigest: ContentDigest(bytes: digest)
            )
        }

        return RecoveryRecord(
            key: RecoveryKey(rawValue: header.key),
            path: header.path,
            title: header.title,
            text: string,
            encoding: header.encoding == "utf8BOM" ? .utf8WithBOM : .utf8,
            baseRevision: base,
            savedAt: Date(timeIntervalSince1970: header.savedAt)
        )
    }

    private static func bytes(fromHex text: String) -> [UInt8]? {
        guard text.utf8.count % 2 == 0 else { return nil }

        var out: [UInt8] = []
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }

            out.append(byte)
            index = next
        }

        return out
    }

    // MARK: Files

    private static func makeDirectory(_ directory: URL) throws {
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw FileStoreError.io(code: Int32((error as NSError).code))
        }
    }

    private static func writeFile(_ record: RecoveryRecord, directory: URL) throws {
        let bytes = try encode(record)
        let final = directory.appendingPathComponent(fileName(for: record.key)).path
        var template = Array("\(directory.path)/.record.XXXXXX.tmp".utf8CString)
        let fd = mkstemps(&template, 4)   // owner-only mode, unique name
        guard fd >= 0 else { throw POSIX.error(errno) }

        let temporary = String(decoding: template.dropLast().map { UInt8(bitPattern: $0) }, as: UTF8.self)
        var renamed = false
        defer {
            close(fd)
            if !renamed { unlink(temporary) }
        }
        var offset = 0
        while offset < bytes.count {
            let count = bytes[offset...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EINTR { continue }
                throw POSIX.error(errno)
            }

            offset += count
        }
        guard fsync(fd) == 0 else { throw POSIX.error(errno) }

        guard rename(temporary, final) == 0 else { throw POSIX.error(errno) }

        renamed = true
    }

    private static func removeIfStale(_ url: URL) {
        guard let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
              Date().timeIntervalSince(modified) > staleTemporaryAge else { return }

        try? FileManager.default.removeItem(at: url)
    }
}
