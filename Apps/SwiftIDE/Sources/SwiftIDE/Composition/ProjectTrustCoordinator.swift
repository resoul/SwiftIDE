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
    private var presentations: [UUID: (owner: DocumentID, parent: NSWindow)] = [:]
    private let presenter = ProjectTrustPresenter()
    private let rootForSession: @MainActor (DocumentSession) -> URL

    init(rootForSession: @escaping @MainActor (DocumentSession) -> URL) {
        self.rootForSession = rootForSession
    }

    func register(_ session: DocumentSession, window: NSWindow) {
        if let old = owners[session.id]?.window, old !== window {
            for presentation in presentations.values where presentation.owner == session.id { presenter.cancel(for: presentation.parent) }
        }

        owners[session.id] = Owner(session: session, window: window)
    }

    func unregister(_ session: DocumentSession) {
        guard owners.removeValue(forKey: session.id) != nil else { return }

        for presentation in presentations.values where presentation.owner == session.id {
            presenter.cancel(for: presentation.parent)
        }
    }

    func ask(projectName: String, root: URL) async -> TrustDecision? {
        let key = DocumentPath.canonical(root.path)
        let matching = owners.values.filter {
            $0.window != nil && !$0.session.isUntitled && DocumentPath.canonical(rootForSession($0.session).path) == key
        }
        // All tabs of a project share its actual window, including Untitled and outside files.
        guard let owner = matching.first(where: { $0.window?.isVisible == true }) ?? matching.first,
              let window = owner.window else { return nil }

        let token = UUID()
        presentations[token] = (owner.session.id, window)
        defer { presentations[token] = nil }

        let decision = await presenter.ask(projectName: projectName, parent: window)
        // The document may have moved or closed while the question was pending.
        guard owners[owner.session.id]?.window === window,
              DocumentPath.canonical(rootForSession(owner.session).path) == key else { return nil }

        return decision
    }
}
