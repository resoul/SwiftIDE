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
        owners[session.id] = Owner(session: session, window: window)
    }

    func unregister(_ session: DocumentSession) {
        guard let owner = owners.removeValue(forKey: session.id), let window = owner.window else { return }

        presenter.cancel(for: window)
        for presentation in presentations.values where presentation.owner == session.id {
            presenter.cancel(for: presentation.parent)
        }
    }

    func ask(projectName: String, root: URL) async -> TrustDecision? {
        let key = DocumentPath.canonical(root.path)
        let matching = owners.values.filter {
            $0.window != nil && !$0.session.isUntitled && DocumentPath.canonical(rootForSession($0.session).path) == key
        }
        // Within this project, prefer the selected native tab. A hidden sibling cannot host a visible sheet.
        guard let owner = matching.first(where: { $0.window?.tabGroup?.selectedWindow === $0.window })
            ?? matching.first(where: { $0.window?.isVisible == true }) ?? matching.first,
              let anchor = owner.window else { return nil }

        // The selected sibling may be Untitled (served by the loose-file server), but its native
        // tab group still belongs to this project. Keep the requesting document as the anchor.
        let selected = anchor.tabGroup?.selectedWindow
        let window = selected.flatMap { $0.tabbingIdentifier == anchor.tabbingIdentifier ? $0 : nil } ?? anchor
        let token = UUID()
        presentations[token] = (owner.session.id, window)
        defer { presentations[token] = nil }

        let decision = await presenter.ask(projectName: projectName, parent: window)
        // The document may have moved or closed while the question was pending.
        let sameProjectWindow = window === anchor || anchor.tabGroup?.windows.contains(where: { $0 === window }) == true
        guard owners[owner.session.id]?.window === anchor, sameProjectWindow,
              window.tabbingIdentifier == anchor.tabbingIdentifier,
              DocumentPath.canonical(rootForSession(owner.session).path) == key else { return nil }

        return decision
    }
}
