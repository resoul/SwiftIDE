import Foundation
import IDEDomain

/// Names one recoverable document. A file is kept under its path, so that the same file is the
/// same document in every run; a document that never had a file is kept under its own id.
public struct RecoveryKey: Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static func file(atPath path: String) -> RecoveryKey {
        RecoveryKey(rawValue: "file:" + path)
    }

    public static func scratch(_ id: DocumentID) -> RecoveryKey {
        RecoveryKey(rawValue: "scratch:" + id.rawValue.uuidString)
    }
}

/// The unsaved text of one document, with what it was based on.
public struct RecoveryRecord: Equatable, Sendable {
    public let key: RecoveryKey
    /// The file the text belongs to; nil for a document that never had one.
    public let path: String?
    /// The name shown when asking about it.
    public let title: String
    public let text: String
    public let encoding: FileEncoding
    /// The file as it was when this text was based on it: what a later save is judged against.
    /// nil for a document without a file, or for a file that did not exist yet.
    public let baseRevision: FileRevision?
    public let savedAt: Date

    public init(
        key: RecoveryKey,
        path: String?,
        title: String,
        text: String,
        encoding: FileEncoding,
        baseRevision: FileRevision?,
        savedAt: Date
    ) {
        self.key = key
        self.path = path
        self.title = title
        self.text = text
        self.encoding = encoding
        self.baseRevision = baseRevision
        self.savedAt = savedAt
    }
}

/// What is stored: the records that could be read, and a description of every entry that could
/// not. An unreadable entry is reported, never dropped without a word.
public struct RecoveryListing: Equatable, Sendable {
    public var records: [RecoveryRecord]
    public var unreadable: [String]

    public init(records: [RecoveryRecord] = [], unreadable: [String] = []) {
        self.records = records
        self.unreadable = unreadable
    }
}

/// Consumer-owned port to the place where unsaved text is kept apart from the file it belongs to.
/// Writing a key replaces what it held; a failed write leaves the previous record as it was.
public protocol RecoveryStore: Sendable {
    func write(_ record: RecoveryRecord) async throws
    /// Removing a key that holds nothing is not an error.
    func remove(_ key: RecoveryKey) async throws
    func pending() async throws -> RecoveryListing
}

/// When unsaved text is written, and for what size of document. Provisional values (ADR-016).
public struct RecoveryPolicy: Sendable, Equatable {
    /// How long after the last edit the text is written.
    public var debounce: Duration
    /// The longest an unsaved edit waits, however steadily the user types.
    public var maximumDelay: Duration
    /// A larger document is not kept: the copy, the write and the record would be too big.
    public var maximumUTF16Length: Int

    public init(
        debounce: Duration = .seconds(2),
        maximumDelay: Duration = .seconds(10),
        maximumUTF16Length: Int = 16 * 1_048_576
    ) {
        self.debounce = debounce
        self.maximumDelay = maximumDelay
        self.maximumUTF16Length = maximumUTF16Length
    }

    public static let standard = RecoveryPolicy()
}
