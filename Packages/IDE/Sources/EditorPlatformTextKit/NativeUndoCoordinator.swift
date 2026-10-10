import AppKit
import IDEApplication
import IDEDomain

/// Owns the single UndoManager of one document. NSTextView registers typing undo in it through
/// `NSTextViewDelegate.undoManager(for:)`; programmatic commits register exactly one inverse
/// here. Application code never sees AppKit undo types.
@MainActor
public final class NativeUndoCoordinator {
    private let manager = DocumentUndoManager()
    private weak var backend: TextKitDocumentBackend?

    /// The one history of this document, shared by native typing and programmatic edits.
    public var undoManager: UndoManager { manager }

    init(backend: TextKitDocumentBackend) {
        self.backend = backend
    }

    /// Called once per programmatic commit, after storage changed. Typing is never registered
    /// here: NSTextView already did that, and a second inverse would double the history.
    func registerProgrammatic(_ plan: PreparedDocumentEdit) {
        manager.registerProgrammatic(target: self, handler: Self.undoHandler(plan.inverseEdits))
    }

    private static func undoHandler(_ edits: [DocumentEdit]) -> @Sendable (NativeUndoCoordinator) -> Void {
        { coordinator in MainActor.assumeIsolated { coordinator.perform(inverse: edits) } }
    }

    /// Inside undo/redo: the opposite step lands on the redo (or undo) stack by itself.
    private func registerInverse(_ edits: [DocumentEdit]) {
        manager.registerUndo(withTarget: self, handler: Self.undoHandler(edits))
    }

    /// Runs inside UndoManager's undo/redo. Registering the opposite step here puts it on the
    /// redo (or undo) stack automatically.
    private func perform(inverse edits: [DocumentEdit]) {
        guard let backend else { return }

        // History that no longer matches the text cannot be applied safely.
        let plan: PreparedDocumentEdit?
        do {
            plan = try DocumentEditPlanner.prepare(edits, in: backend)
        } catch {
            undoManager.removeAllActions(withTarget: self)

            return
        }
        guard let plan else { return }

        registerInverse(plan.inverseEdits)
        backend.replaceManaged(plan)
    }
}
