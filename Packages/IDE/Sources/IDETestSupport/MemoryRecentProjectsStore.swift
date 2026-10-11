import IDEApplication

@MainActor
public final class MemoryRecentProjectsStore: RecentProjectsStore {
    public private(set) var projects: [RecentProject]
    public init(projects: [RecentProject] = []) { self.projects = projects }
    public func load() throws -> [RecentProject] { projects }
    public func save(_ projects: [RecentProject]) throws { self.projects = projects }
}
