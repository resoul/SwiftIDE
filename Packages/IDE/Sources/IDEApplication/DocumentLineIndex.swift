import Foundation
import IDEDomain

/// The line index of one open document, kept in step with its session.
///
/// It listens to the session's change sets and applies each edit to the index, so asking
/// "which line is this offset on" never reads the text. It checks itself after every change set
/// (version continuity and total length, both O(1)) and rebuilds from the backend when they
/// disagree, which is how it recovers from a change it could not follow.
@MainActor
public final class DocumentLineIndex {
    public private(set) var index: LineIndex
    /// How many times the index was rebuilt by reading the text again, the initial build excluded.
    public private(set) var rebuildCount = 0
    private var observers: [UUID: @MainActor () -> Void] = [:]

    private let session: DocumentSession
    private let source: any TextSource
    /// The session version the index describes; nil when the index may be out of step.
    private var trackedVersion: UInt64?
    private var subscription: UUID?

    public init(session: DocumentSession, source: any TextSource) {
        self.session = session
        self.source = source
        index = LineIndex(scanning: source)
        trackedVersion = source.utf16Length == session.utf16Length ? session.version : nil
        subscription = session.subscribeToChanges { [weak self] changes in
            self?.apply(changes)
        }
    }

    /// Calls `observer` after the index changed: views showing line numbers redraw, the long-line
    /// monitor looks again. Observers run in no particular order.
    @discardableResult
    public func subscribe(_ observer: @escaping @MainActor () -> Void) -> UUID {
        let id = UUID()
        observers[id] = observer
        return id
    }

    public func unsubscribe(_ id: UUID) {
        observers.removeValue(forKey: id)
    }

    /// The index, rebuilt first if it is known to be out of step and the text can be trusted.
    public var current: LineIndex {
        if trackedVersion == nil { rebuild() }
        return index
    }

    private func apply(_ changes: DocumentChangeSet) {
        defer { for observer in Array(observers.values) { observer() } }
        guard changes.oldVersion == trackedVersion else { return rebuild() }
        for edit in changes.edits {   // descending: earlier positions stay valid
            guard index.replace(edit.range, with: edit.replacement) else { return rebuild() }
        }
        trackedVersion = changes.newVersion
        if index.utf16Length != session.utf16Length { rebuild() }
    }

    private func rebuild() {
        rebuildCount += 1
        index = LineIndex(scanning: source)
        // A backend ahead of the session (an edit not yet accounted for) cannot be paired with a
        // version; the next change set finds that out and tries again.
        trackedVersion = source.utf16Length == session.utf16Length ? session.version : nil
    }
}
