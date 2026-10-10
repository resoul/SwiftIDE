import Foundation
import IDEApplication

/// Scoped by the same canonical root as ProjectContexts. No settings are written into the project.
@MainActor
final class ProjectFilesSettings {
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private func key(_ root: String) -> String { "projectFiles.exclusions.v1." + DocumentPath.canonical(root) }

    func load(root: String) -> ProjectExclusions {
        guard let data = defaults.data(forKey: key(root)), let value = try? JSONDecoder().decode(ProjectExclusions.self, from: data) else {
            return .init()
        }

        return value
    }

    func save(_ value: ProjectExclusions, root: String) {
        defaults.set(try? JSONEncoder().encode(value), forKey: key(root))
    }
}
