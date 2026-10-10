
public struct DocumentSnapshot: Equatable, Sendable {
    public let documentID: DocumentID
    public let path: String
    public let version: UInt64
    public let text: String
    public let encoding: FileEncoding

    public init(
        documentID: DocumentID,
        path: String,
        version: UInt64,
        text: String,
        encoding: FileEncoding = .utf8
    ) {
        self.documentID = documentID
        self.path = path
        self.version = version
        self.text = text
        self.encoding = encoding
    }
}
