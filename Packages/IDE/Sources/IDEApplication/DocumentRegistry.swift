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
    // A few open documents: scanning beats a path-keyed index that Save As would have to keep in
    // step with the session (a document changes its path when it is saved under a new name).
    private var sessions: [DocumentSession] = []
    // Names that a Save As is about to give a document. It can wait for a long time (for a
    // composition to end), and during that time nobody else may take the name.
    private var reservations: [String: DocumentID] = [:]

    public init() {}

    public var openDocuments: [DocumentSession] { sessions }

    public func session(atPath path: String) -> DocumentSession? {
        let canonical = DocumentPath.canonical(path)

        return sessions.first { !$0.isUntitled && $0.path == canonical }
    }

    /// An open document whose file is `identity`, whatever name it was opened under.
    public func session(withFileID identity: FileIdentity) -> DocumentSession? {
        sessions.first { $0.diskRevision?.fileID == identity }
    }

    public enum Reservation: Sendable {
        case granted
        /// Another open document already edits that file.
        case openElsewhere
        /// Another Save As is already going to that name.
        case reserved
    }

    /// Takes `path` for `document` for the whole of a Save As. While it is held, opening that
    /// file and saving another document under that name are refused, so two windows can never
    /// end up with the same file.
    public func reserve(path: String, for document: DocumentSession) -> Reservation {
        let canonical = DocumentPath.canonical(path)
        if let other = session(atPath: canonical), other !== document { return .openElsewhere }
        guard reservations[canonical] == nil else { return .reserved }

        reservations[canonical] = document.id

        return .granted
    }

    public func releaseReservation(path: String, for document: DocumentSession) {
        let canonical = DocumentPath.canonical(path)
        if reservations[canonical] == document.id { reservations.removeValue(forKey: canonical) }
    }

    public func isReserved(path: String) -> Bool {
        reservations[DocumentPath.canonical(path)] != nil
    }

    /// Idempotent. A scratch document joins when it is first saved under a name.
    public func register(_ session: DocumentSession) {
        if !sessions.contains(where: { $0 === session }) { sessions.append(session) }
    }

    /// Closing a document releases its file so it can be opened again.
    public func remove(_ session: DocumentSession) {
        sessions.removeAll { $0 === session }
    }
}
