import AppKit
import IDEApplication

/// Covers every open document in the worktree, including other project and standalone windows.
@MainActor
final class GitCheckoutCoordinator {
    private let documents: () -> [DocumentEditorController]
    private let prompt: ((DocumentSession) async -> GitCheckoutDocuments.Decision)?
    private var lockedRoots: Set<String> = []

    init(
        documents: @escaping () -> [DocumentEditorController],
        prompt: ((DocumentSession) async -> GitCheckoutDocuments.Decision)? = nil
    ) {
        self.documents = documents; self.prompt = prompt
    }

    func prepare(_ repository: GitRepository) async -> Bool {
        guard !lockedRoots.contains(repository.root) else { return false }

        let reconciliation = GitCheckoutDocuments(
            documents: { [documents] in documents().filter { !$0.isClosed }.map(\.session) },
            prompt: { [weak self] session in
            guard let self, let document = documents().first(where: { $0.session === session }),
                  !document.isSaving else {
                return .cancel
            }

            if let prompt { return await prompt(session) }

            return await ask(document)
        },
            save: { [documents] session in await documents().first { $0.session === session }?.save() ?? false }
        )
        guard await reconciliation.prepare(root: repository.root), !Task.isCancelled,
              affected(repository.root).allSatisfy({ !$0.isSaving && !$0.session.isComposing && !$0.session.isDirty })
              else {
                  return false
              }

        lockedRoots.insert(repository.root)
        for document in affected(repository.root) { document.setGitCheckoutLocked(true) }

        return true
    }
    func register(_ document: DocumentEditorController) {
        if lockedRoots.contains(where: { GitCheckoutDocuments.contains(document.session, root: $0) }) {
            document.setGitCheckoutLocked(true)
        }
    }
    func finish(_ repository: GitRepository) {
        guard lockedRoots.remove(repository.root) != nil else { return }

        for document in affected(repository.root) {
            document.setGitCheckoutLocked(false)
            document.checkDiskAfterGit()
        }
    }
    private func affected(_ root: String) -> [DocumentEditorController] {
        documents().filter { !$0.isClosed && GitCheckoutDocuments.contains($0.session, root: root) }
    }
    private func ask(_ document: DocumentEditorController) async -> GitCheckoutDocuments.Decision {
        guard let window = document.window, window.attachedSheet == nil else { return .cancel }

        let alert = NSAlert()
        alert.messageText = "Save “\(document.displayName)” before updating files?"
        alert.informativeText = """
        This Git action changes files on disk. Save this document or cancel the action; its unsaved text will not be \
        discarded.
        """
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Save")
        let response = await withTaskCancellationHandler {
            await alert.beginSheetModal(for: window)
        } onCancel: {
            Task { @MainActor in
                if alert.window.sheetParent === window { window.endSheet(alert.window, returnCode: .abort) }
            }
        }

        return response == .alertSecondButtonReturn && !Task.isCancelled && !document.isClosed ? .save : .cancel
    }
}
