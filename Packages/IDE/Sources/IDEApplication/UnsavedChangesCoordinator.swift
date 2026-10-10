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
    ///
    /// Letting go of what the app keeps for the discarded documents (their recovery copies) takes
    /// time, and the world moves meanwhile just as it does while a sheet is open. So that is part
    /// of the procedure, not something done after it: `release` is given the documents whose
    /// changes the user agreed to lose, and when it returns everything is checked again; text
    /// typed meanwhile is asked about, a new window is asked about, and documents are released
    /// again for their new text. If the quit is then refused, `reinstate` is given every document
    /// that was released, so that they are protected again.
    public func canQuit(
        documents: @MainActor () -> [DocumentSession],
        release: @MainActor ([DocumentSession]) async -> Void = { _ in },
        reinstate: @MainActor ([DocumentSession]) -> Void = { _ in }
    ) async -> Bool {
        var discarded: [DocumentID: UInt64] = [:]
        var released: [DocumentID: (session: DocumentSession, version: UInt64)] = [:]
        while true {
            let open = documents()
            if let session = open.first(where: { $0.isDirty && discarded[$0.id] != $0.version }) {
                switch await resolve(session) {
                case .refused:
                    if !released.isEmpty { reinstate(released.values.map(\.session)) }
                    return false
                case .settled: break
                case .discarded(let version): discarded[session.id] = version
                }
                continue
            }
            let unreleased = open.filter { $0.isDirty && released[$0.id]?.version != $0.version }
            guard !unreleased.isEmpty else { return true }
            for session in unreleased { released[session.id] = (session, session.version) }
            await release(unreleased)
        }
    }
}
