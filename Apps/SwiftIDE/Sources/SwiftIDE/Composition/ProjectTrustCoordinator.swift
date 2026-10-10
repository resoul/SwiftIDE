import AppKit
import IDEApplication
import IDEDomain
import WorkspaceUI

/// App resolves the project's owning window; WorkspaceUI only presents the supplied question.
@MainActor
final class ProjectTrustCoordinator {
    private struct Owner {
        let session: DocumentSession
        weak var window: NSWindow?
    }

    private var owners: [DocumentID: Owner] = [:]
    private let presenter = ProjectTrustPresenter()
    private let rootForSession: @MainActor (DocumentSession) -> URL

    init(rootForSession: @escaping @MainActor (DocumentSession) -> URL) {
        self.rootForSession = rootForSession
    }

    func register(_ session: DocumentSession, window: NSWindow) {
        owners[session.id] = Owner(session: session, window: window)
    }

    func unregister(_ session: DocumentSession) {
        guard let owner = owners.removeValue(forKey: session.id), let window = owner.window else { return }

        presenter.cancel(for: window)
    }

    func ask(projectName: String, root: URL) async -> TrustDecision? {
        let key = DocumentPath.canonical(root.path)
        guard let owner = owners.values.first(where: {
            $0.window != nil && !$0.session.isUntitled && DocumentPath.canonical(rootForSession($0.session).path) == key
        }), let window = owner.window else { return nil }

        let decision = await presenter.ask(projectName: projectName, parent: window)
        // The document may have moved or closed while the question was pending.
        guard owners[owner.session.id]?.window === window,
              DocumentPath.canonical(rootForSession(owner.session).path) == key else { return nil }

        return decision
    }
}
