import IDEDomain

public enum UnsavedChangesDecision: Sendable {
    case save, discard, cancel
}

/// One decision procedure for every way a document can go away: closing its window and quitting
/// the app. AppKit does not ask a window's delegate when the app quits, so the procedure cannot
/// live in the window.
@MainActor
public final class UnsavedChangesCoordinator {
    private let prompt: @MainActor (DocumentSession) async -> UnsavedChangesDecision
    private let save: @MainActor (DocumentSession) async -> Bool
    private var deciding: Set<DocumentID> = []

    /// `prompt` asks the user (and may offer only Discard/Cancel for a document that cannot be
    /// saved). `save` performs the save, shows its own failures, and returns whether the write
    /// succeeded.
    public init(
        prompt: @escaping @MainActor (DocumentSession) async -> UnsavedChangesDecision,
        save: @escaping @MainActor (DocumentSession) async -> Bool
    ) {
        self.prompt = prompt
        self.save = save
    }

    private enum Outcome {
        /// The user said no, a save failed, or another question about it is already open.
        case refused
        /// Nothing unsaved is left, as of now.
        case settled
        /// The user agreed to lose exactly this version of the text, and nothing newer.
        case discarded(version: UInt64)
    }

    private func resolve(_ session: DocumentSession) async -> Outcome {
        guard session.isDirty else { return .settled }
        // One question per document at a time; a second request does not stack another sheet.
        guard deciding.insert(session.id).inserted else { return .refused }
        defer { deciding.remove(session.id) }

        // What the user is looking at when asked. Their answer covers this and nothing later.
        let seen = session.version
        switch await prompt(session) {
        case .cancel:
            return .refused
        case .discard:
            return .discarded(version: seen)
        case .save:
            guard await save(session) else { return .refused }
            // A successful write only covers the text it captured. Anything typed while it was
            // being written is new and unsaved, and closing now would lose it.
            return session.isDirty ? .refused : .settled
        }
    }

    /// Whether the document may be dropped now.
    public func canClose(_ session: DocumentSession) async -> Bool {
        switch await resolve(session) {
        case .refused: false
        case .settled: true
        // Text that changed while the question was open is newer than what was agreed to lose.
        case .discarded(let version): session.version == version
        }
    }

    /// Whether the app may quit.
    ///
    /// Documents are asked about one at a time, and every answer is tied to the version it was
    /// given for. After each answer the set of documents is read again, because the world moves
    /// while a sheet is open: a document already settled can be edited, and windows can appear.
    /// Quitting is allowed only by a pass that finds every document either clean or discarded at
    /// its current version; that last pass runs without suspending, so nothing can change
    /// between it and the caller's reply. It stops at the first answer that keeps the app running.
    public func canQuit(documents: @MainActor () -> [DocumentSession]) async -> Bool {
        var discarded: [DocumentID: UInt64] = [:]
        while true {
            let pending = documents().first { $0.isDirty && discarded[$0.id] != $0.version }
            guard let session = pending else { return true }
            switch await resolve(session) {
            case .refused: return false
            case .settled: break
            case .discarded(let version): discarded[session.id] = version
            }
        }
    }
}
