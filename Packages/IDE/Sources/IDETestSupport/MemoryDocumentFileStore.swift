import IDEApplication
import IDEDomain

/// Demo adapter: process-local storage, no filesystem writes.
public actor MemoryDocumentFileStore: DocumentFileStore {
    private var contents: [String: String]

    public init(contents: [String: String] = [:]) {
        self.contents = contents
    }

    public func write(_ snapshot: DocumentSnapshot) async throws {
        try Task.checkCancellation()
        contents[snapshot.path] = snapshot.text
    }

    public func text(at path: String) -> String? {
        contents[path]
    }
}
