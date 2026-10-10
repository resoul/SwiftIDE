import Foundation

public struct UTF16TextRange: Equatable, Sendable {
    public let location: Int
    public let length: Int

    public init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }
}

public struct DocumentEdit: Equatable, Sendable {
    public let range: UTF16TextRange
    public let replacement: String

    public init(range: UTF16TextRange, replacement: String) {
        self.range = range
        self.replacement = replacement
    }
}

public enum EditOrigin: Sendable {
    case command, typing, composition, undo, redo, formatting, languageAction
}

public struct TransactionID: Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public enum CompositionEvent: Equatable, Sendable {
    case began, updated, ended
}

public struct DocumentChangeSet: Sendable {
    public let documentID: DocumentID
    public let oldVersion: UInt64
    public let newVersion: UInt64
    public let edits: [DocumentEdit]
    public let origin: EditOrigin
    public let transactionID: TransactionID
    public let isReconciled: Bool

    public init(
        documentID: DocumentID,
        oldVersion: UInt64,
        newVersion: UInt64,
        edits: [DocumentEdit],
        origin: EditOrigin,
        transactionID: TransactionID = TransactionID(),
        isReconciled: Bool = false
    ) {
        self.documentID = documentID
        self.oldVersion = oldVersion
        self.newVersion = newVersion
        self.edits = edits
        self.origin = origin
        self.transactionID = transactionID
        self.isReconciled = isReconciled
    }
}
