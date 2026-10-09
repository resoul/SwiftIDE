import IDEDomain

/// The open documents of one workspace.
///
/// A document is identified by its file, not only by its name: the canonical path catches
/// symlinks and `..`, the file identity of the last revision read or written catches other names
/// of the same file (hard links). An atomic save gives a file a new inode, so the identity is
/// read from the session's current revision each time instead of being recorded once; after a
/// save through one name, the other hard link is a different file and opens as its own document.
@MainActor
public final class DocumentRegistry {
    private var sessions: [String: DocumentSession] = [:]

    public init() {}

    public var openDocuments: [DocumentSession] { Array(sessions.values) }

    public func session(atPath path: String) -> DocumentSession? {
        sessions[DocumentPath.canonical(path)]
    }

    /// An open document whose file is `identity`, whatever name it was opened under.
    public func session(withFileID identity: FileIdentity) -> DocumentSession? {
        sessions.values.first { $0.diskRevision?.fileID == identity }
    }

    func insert(_ session: DocumentSession) {
        sessions[session.path] = session
    }

    /// Closing a document releases its path so it can be opened again.
    public func remove(_ session: DocumentSession) {
        if sessions[session.path] === session { sessions.removeValue(forKey: session.path) }
    }
}
