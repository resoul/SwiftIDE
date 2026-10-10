import Foundation

public struct FileIdentity: Hashable, Sendable {
    public let device: UInt64
    public let inode: UInt64

    public init(device: UInt64, inode: UInt64) {
        self.device = device
        self.inode = inode
    }
}

public struct ContentDigest: Hashable, Sendable {
    public let bytes: [UInt8]

    public init(bytes: [UInt8]) {
        self.bytes = bytes
    }
}

public struct FileRevision: Hashable, Sendable {
    public let fileID: FileIdentity
    public let size: UInt64
    public let modificationTime: Int64
    public let contentDigest: ContentDigest

    public init(fileID: FileIdentity, size: UInt64, modificationTime: Int64, contentDigest: ContentDigest) {
        self.fileID = fileID
        self.size = size
        self.modificationTime = modificationTime
        self.contentDigest = contentDigest
    }
    
    public func hasSameContent(as other: FileRevision) -> Bool {
        size == other.size && contentDigest == other.contentDigest
    }
}

public enum FileEncoding: Equatable, Sendable {
    case utf8
    case utf8WithBOM
}

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

public enum SaveExpectation: Equatable, Sendable {
    case revision(FileRevision?)
    case overwrite
}

public enum FileStoreError: Error, Equatable, Sendable {
    case conflict(current: FileRevision?)
    case notFound
    case notRegularFile
    case permissionDenied
    case tooLarge(size: UInt64, limit: Int)
    case binary
    case notUTF8
    case unsupportedEncoding
    case changedWhileReading
    case cannotPreserveMetadata(code: Int32)
    case io(code: Int32)
}
