import Foundation

/// Identity of a file independent of its path: it survives renames and differs after the file
/// was replaced by another one.
public struct FileIdentity: Hashable, Sendable {
    public let device: UInt64
    public let inode: UInt64

    public init(device: UInt64, inode: UInt64) {
        self.device = device
        self.inode = inode
    }
}

/// Digest of the exact bytes of a file.
public struct ContentDigest: Hashable, Sendable {
    public let bytes: [UInt8]

    public init(bytes: [UInt8]) {
        self.bytes = bytes
    }
}

/// What the app knew about a file the last time it read or wrote it.
///
/// Whether a file changed is decided by its bytes (`contentDigest`), never by metadata: size and
/// timestamps can be restored by the program that changed it. A file that was only touched, or
/// replaced by an editor with identical bytes, is therefore not a conflict. `fileID`, `size` and
/// `modificationTime` describe the file for display and for telling files apart.
public struct FileRevision: Hashable, Sendable {
    public let fileID: FileIdentity
    public let size: UInt64
    /// Nanoseconds since 1970; `Date` would lose the precision the comparison relies on.
    public let modificationTime: Int64
    public let contentDigest: ContentDigest

    public init(fileID: FileIdentity, size: UInt64, modificationTime: Int64, contentDigest: ContentDigest) {
        self.fileID = fileID
        self.size = size
        self.modificationTime = modificationTime
        self.contentDigest = contentDigest
    }

    /// Exact same bytes, whatever the metadata says.
    public func hasSameContent(as other: FileRevision) -> Bool {
        size == other.size && contentDigest == other.contentDigest
    }
}

/// Encoding metadata that must survive a save. Line endings need none: they stay in the text.
public enum FileEncoding: Equatable, Sendable {
    case utf8
    case utf8WithBOM
}

/// Result of opening a file. `path` is the canonical path the file was read from.
public struct LoadedFile: Equatable, Sendable {
    public let path: String
    public let text: String
    public let encoding: FileEncoding
    public let revision: FileRevision

    public init(path: String, text: String, encoding: FileEncoding, revision: FileRevision) {
        self.path = path
        self.text = text
        self.encoding = encoding
        self.revision = revision
    }
}

/// What a save is allowed to assume about the file on disk.
public enum SaveExpectation: Equatable, Sendable {
    /// The file must still be the one read or written last. `nil`: it must not exist yet.
    case revision(FileRevision?)
    /// The user explicitly chose to replace whatever is on disk.
    case overwrite
}

public enum FileStoreError: Error, Equatable, Sendable {
    /// The file on disk is not what the save was based on. `current` is nil if it is gone.
    case conflict(current: FileRevision?)
    case notFound
    case notRegularFile
    case permissionDenied
    case tooLarge(size: UInt64, limit: Int)
    /// Contains NUL bytes: not text, whatever its extension says.
    case binary
    case notUTF8
    /// A UTF-16 or UTF-32 byte-order mark: valid text, but not supported yet.
    case unsupportedEncoding
    /// The file changed while it was being read, so the bytes cannot be trusted.
    case changedWhileReading
    /// Permissions, owner, ACLs or extended attributes could not be carried over to the
    /// replacement, so nothing was written: a save must not quietly drop them.
    case cannotPreserveMetadata(code: Int32)
    case io(code: Int32)
}
