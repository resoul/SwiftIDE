import Foundation
import IDEDomain

public enum DocumentError: Error, Equatable, Sendable {
    case staleVersion(expected: UInt64, actual: UInt64)
    case versionExhausted
    case reentrantEdit
}

/// Owns revision/save metadata. Its injected backend is the only text owner.
@MainActor
public final class DocumentSession {
    public let id: DocumentID
    public let path: String
    private let backend: any DocumentEditingBackend
    private var observers: [UUID: @MainActor (DocumentChangeSet) -> Void] = [:]
    private var isPublishing = false
    public var text: String { backend.text }
    public private(set) var version: UInt64 = 0
    public private(set) var savedVersion: UInt64 = 0

    public var isDirty: Bool { version != savedVersion }

    /// Represents content already loaded from storage.
    public init(id: DocumentID = DocumentID(), path: String, backend: any DocumentEditingBackend) {
        self.id = id
        self.path = path
        self.backend = backend
    }

    public func replaceText(_ replacement: String, expectedVersion: UInt64) throws {
        try apply(
            [DocumentEdit(range: UTF16TextRange(location: 0, length: text.utf16.count), replacement: replacement)],
            expectedVersion: expectedVersion
        )
    }

    public func apply(
        _ edits: [DocumentEdit], expectedVersion: UInt64, origin: EditOrigin = .command
    ) throws {
        guard !isPublishing else { throw DocumentError.reentrantEdit }
        guard expectedVersion == version else {
            throw DocumentError.staleVersion(expected: expectedVersion, actual: version)
        }
        guard let plan = try DocumentEditPlanner.prepare(edits, in: backend.text) else { return }
        guard version < UInt64.max else { throw DocumentError.versionExhausted }
        let oldVersion = version
        backend.commit(plan)
        version += 1
        let change = DocumentChangeSet(
            documentID: id, oldVersion: oldVersion, newVersion: version,
            edits: plan.edits, origin: origin
        )
        // Broadcast one committed transaction to every active subscriber.
        // Observers enqueue background work; nested text edits must wait until publication ends.
        isPublishing = true
        defer { isPublishing = false }
        for observer in Array(observers.values) { observer(change) }
    }

    @discardableResult
    public func subscribeToChanges(_ observer: @escaping @MainActor (DocumentChangeSet) -> Void) -> UUID {
        let id = UUID()
        observers[id] = observer
        return id
    }

    public func unsubscribeFromChanges(_ id: UUID) {
        observers.removeValue(forKey: id)
    }

    public func snapshot() -> DocumentSnapshot {
        DocumentSnapshot(documentID: id, path: path, version: version, text: text)
    }

    // Only application scenarios can acknowledge persistence.
    func acknowledgeSave(of snapshot: DocumentSnapshot) {
        precondition(snapshot.documentID == id && snapshot.path == path)
        precondition(snapshot.version <= version)
        savedVersion = snapshot.version
    }
}
