import Foundation
import IDEApplication
import WorkspaceUI

@MainActor
final class WorkspaceLayoutSettings {
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func makeState(root: String) -> WorkspaceLayoutState {
        let key = "workspace.layout.v1." + DocumentPath.canonical(root)
        let layout = defaults.data(forKey: key)
            .flatMap { try? JSONDecoder().decode(WorkspaceLayout.self, from: $0) } ?? .init()
        let state = WorkspaceLayoutState(layout: layout)
        state.onSave = { [defaults] in defaults.set(try? JSONEncoder().encode($0), forKey: key) }

        return state
    }
}
