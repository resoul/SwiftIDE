import Foundation
import IDEApplication

@MainActor
final class UserDefaultsRecentProjectsStore: RecentProjectsStore {
    private struct Archive: Codable {
        let version: Int
        let projects: [RecentProject]
    }
    private let defaults: UserDefaults
    private let key = "recentProjects.v1"
    private var canSave = true

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load() throws -> [RecentProject] {
        guard defaults.object(forKey: key) != nil else { return [] }

        do {
            guard let data = defaults.data(forKey: key) else { throw ArchiveError.unreadable }

            let archive = try JSONDecoder().decode(Archive.self, from: data)
            guard archive.version == 1 else { throw ArchiveError.unreadable }

            return archive.projects
        } catch {
            canSave = false
            throw ArchiveError.unreadable
        }
    }

    func save(_ projects: [RecentProject]) throws {
        guard canSave else { throw ArchiveError.unreadable }

        defaults.set(try JSONEncoder().encode(Archive(version: 1, projects: projects)), forKey: key)
    }
}

private enum ArchiveError: LocalizedError {
    case unreadable
    var errorDescription: String? {
        "The existing project list is unreadable or from a newer version. It has been kept."
    }
}
