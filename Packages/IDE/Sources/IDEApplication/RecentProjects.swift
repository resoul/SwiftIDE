import Foundation

public struct RecentProject: Codable, Equatable, Sendable, Identifiable {
    public let path: String
    public var lastOpened: Date
    public var isPinned: Bool
    public var id: String { path }
    public var name: String { (path as NSString).lastPathComponent }

    public init(path: String, lastOpened: Date, isPinned: Bool = false) {
        self.path = path
        self.lastOpened = lastOpened
        self.isPinned = isPinned
    }
}

@MainActor
public protocol RecentProjectsStore {
    func load() throws -> [RecentProject]
    func save(_ projects: [RecentProject]) throws
}

public enum ProjectFolderAvailability: Equatable, Sendable {
    case checking
    case available(canonicalPath: String)
    case missing
    case unavailable(String)
}

public protocol ProjectFolderChecking: Sendable {
    /// Checks only the root, without scanning the tree, loading a manifest or launching tools.
    func check(path: String) async -> ProjectFolderAvailability
}

/// Recent metadata is persistent; open roots, search, selection and availability are session state.
@MainActor
public final class RecentProjects {
    public private(set) var projects: [RecentProject]
    public private(set) var openRoots: Set<String> = []
    public private(set) var availability: [String: ProjectFolderAvailability] = [:]
    public private(set) var storageIssue: String?
    public private(set) var isChecking = false
    public var query = "" { didSet { changed() } }
    public var selection: String?
    private let store: any RecentProjectsStore
    private let checker: any ProjectFolderChecking
    private var refreshTask: Task<Void, Never>?
    private var generation = UUID()
    private var observers: [UUID: () -> Void] = [:]

    public init(store: any RecentProjectsStore, checker: any ProjectFolderChecking) {
        self.store = store
        self.checker = checker
        do {
            projects = Self.normalized(try store.load())
        } catch {
            projects = []
            storageIssue = "Recent projects could not be loaded: \(error.localizedDescription)"
        }
    }

    public var visible: [RecentProject] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)

        return projects.filter {
            search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.path
                .localizedCaseInsensitiveContains(search)
        }
    }

    /// Called only after App has successfully opened/focused the checked canonical root.
    public func opened(
        canonicalPath path: String,
        at date: Date = .now,
        replacing oldPath: String? = nil,
        checked: Bool = true
    ) {
        let pinned = projects.contains { ($0.path == path || $0.path == oldPath) && $0.isPinned }
        projects.removeAll { $0.path == path || $0.path == oldPath }
        projects.append(.init(path: path, lastOpened: date, isPinned: pinned))
        projects = Self.normalized(projects)
        if checked { availability[path] = .available(canonicalPath: path) }
        if let oldPath, oldPath != path { availability[oldPath] = nil }
        selection = path
        persist()
    }

    public func pin(_ path: String, pinned: Bool) {
        guard let index = projects.firstIndex(where: { $0.path == path }) else { return }

        projects[index].isPinned = pinned
        projects = Self.normalized(projects)
        persist()
    }

    /// Removes history only. The project and its independent settings are untouched.
    public func remove(_ path: String) {
        projects.removeAll { $0.path == path }
        availability[path] = nil
        if selection == path { selection = nil }
        persist()
    }

    public func setOpenRoots(_ roots: Set<String>) {
        guard roots != openRoots else { return }

        openRoots = roots
        changed()
    }

    /// A user-requested check is newer than any background check already in flight.
    public func checked(_ path: String, state: ProjectFolderAvailability) {
        guard projects.contains(where: { $0.path == path }) else { return }

        availability[path] = state
        changed()
    }

    public func refreshAvailability() {
        refreshTask?.cancel()
        let token = UUID()
        generation = token
        isChecking = true
        let paths = projects.map(\.path)
        availability = Dictionary(uniqueKeysWithValues: paths.map { ($0, .checking) })
        changed()
        let checker = checker
        refreshTask = Task { [weak self] in
            defer {
                if let self, self.generation == token { self.isChecking = false; self.changed() }
            }
            await withTaskGroup(of: (String, ProjectFolderAvailability).self) { group in
                var pending = paths.makeIterator()
                for _ in 0..<min(4, paths.count) {
                    if let path = pending.next() { group.addTask { (path, await checker.check(path: path)) } }
                }
                while let (path, state) = await group.next() {
                    guard !Task.isCancelled, let self, self.generation == token else { group.cancelAll(); return }

                    if self.projects.contains(where: { $0.path == path }) {
                        // A successful explicit opening can be newer than a slow background check.
                        if case .checking = self.availability[path] { self.availability[path] = state; self.changed() }
                    }

                    if let path = pending.next() { group.addTask { (path, await checker.check(path: path)) } }
                }
            }
        }
    }

    public func stopChecking() {
        generation = UUID()
        refreshTask?.cancel()
        refreshTask = nil
        isChecking = false
    }

    @discardableResult
    public func subscribe(_ observer: @escaping () -> Void) -> UUID {
        let id = UUID()
        observers[id] = observer

        return id
    }
    public func unsubscribe(_ id: UUID) { observers[id] = nil }

    private func persist() {
        do {
            try store.save(projects)
            storageIssue = nil
        } catch {
            storageIssue = "Recent projects could not be saved: \(error.localizedDescription)"
        }
        changed()
    }

    private func changed() { for observer in Array(observers.values) { observer() } }

    private static func normalized(_ input: [RecentProject]) -> [RecentProject] {
        var unique: [String: RecentProject] = [:]
        for entry in input where entry.path.hasPrefix("/") && entry.lastOpened.timeIntervalSince1970.isFinite {
            // Lexical normalization only: loading history must never touch the filesystem.
            let path = URL(fileURLWithPath: entry.path).standardizedFileURL.path
            let previous = unique[path]
            unique[path] = .init(
                path: path,
                lastOpened: max(entry.lastOpened, previous?.lastOpened ?? .distantPast),
                isPinned: entry.isPinned || previous?.isPinned == true
            )
        }
        let ordered = unique.values.sorted {
            if $0.isPinned != $1.isPinned { return $0.isPinned }
            if $0.lastOpened != $1.lastOpened { return $0.lastOpened > $1.lastOpened }

            return $0.path < $1.path
        }
        var unpinned = 0

        return ordered.filter { entry in
            if entry.isPinned { return true }

            unpinned += 1

            return unpinned <= 50
        }
    }
}
