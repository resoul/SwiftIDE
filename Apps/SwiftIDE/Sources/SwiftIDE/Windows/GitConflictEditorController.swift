import AppKit
import IDEApplication
import WorkspaceUI

/// Embeds the original document controller. Its storage, Undo, caret and save ownership stay intact.
@MainActor
final class GitConflictEditorController: NSViewController {
    let context: GitConflictViewController
    let document: DocumentEditorController?
    private var task: Task<Void, Never>?
    var reportError: ((String) -> Void)?

    init(workspace: GitWorkspace, conflict: GitConflict, document: DocumentEditorController?) {
        self.document = document
        context = GitConflictViewController(workspace: workspace, conflict: conflict)
        super.init(nibName: nil, bundle: nil)
        context.canEditResult = { [weak document] in (document?.focusTarget as? NSTextView)?.isEditable == true }
        context.takeTextSide = { [weak self] in self?.take($0) }
        context.resolveWorking = { [weak workspace] in workspace?.perform(.resolveConflict(conflict, .workingFile)) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        addChild(context)
        view = context.view
    }

    func attachEditor() {
        _ = view
        if let document {
            document.removeFromParent()
            addChild(document)
            context.installEditor(document.view)
        }
    }

    func detachEditor() {
        context.installEditor(nil)
        document?.removeFromParent()
    }

    func stop() {
        task?.cancel()
        detachEditor()
        context.disconnect()
    }

    private func take(_ side: GitConflictSide) {
        guard context.workspace.canMutate, let document, let text = side.text,
              let snapshot = context.workspace.snapshot,
              let reader = context.workspace.conflictReader else {
            return
        }

        task?.cancel()
        let version = document.session.version, path = document.session.path
        task = Task { [weak self, weak document] in
            do {
                let fresh = try await reader.conflict(in: snapshot, path: self?.context.conflict.path ?? "")
                try Task.checkCancellation()
                guard let self, let document, !document.isClosed, document.session.path == path,
                      context.workspace.canMutate, fresh.indexToken == context.conflict.indexToken,
                      fresh.integration == context.conflict.integration,
                      (document.focusTarget as? NSTextView)?.isEditable == true else {
                    throw GitInspectionError.failed("Conflict or editor changed; reopen its preview")
                }

                try document.session.replaceText(text, expectedVersion: version)
            } catch { if !Task.isCancelled { self?.reportError?(error.localizedDescription) } }
        }
    }
}
