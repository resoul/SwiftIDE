/// Independent immutable text value crossing the async persistence boundary.
public struct DocumentSnapshot: Equatable, Sendable {
    public let documentID: DocumentID
    public let path: String
    public let version: UInt64
    public let text: String

    public init(documentID: DocumentID, path: String, version: UInt64, text: String) {
        self.documentID = documentID
        self.path = path
        self.version = version
        self.text = text
    }
}
