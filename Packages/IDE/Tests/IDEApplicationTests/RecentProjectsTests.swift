import Foundation
import IDEApplication
import IDETestSupport
import Testing

private actor DelayedFolderChecker: ProjectFolderChecking {
    var calls: [(String, CheckedContinuation<ProjectFolderAvailability, Never>)] = []
    func check(path: String) async -> ProjectFolderAvailability {
        await withCheckedContinuation { calls.append((path, $0)) }
    }
    var count: Int { calls.count }
    func path(_ index: Int) -> String { calls[index].0 }
    func finish(_ index: Int, _ result: ProjectFolderAvailability) { calls[index].1.resume(returning: result) }
}

private struct ImmediateFolderChecker: ProjectFolderChecking {
    func check(path: String) async -> ProjectFolderAvailability { .available(canonicalPath: path) }
}

@MainActor
struct RecentProjectsTests {
    @Test func recentListDeduplicatesOrdersPinsBoundsHistoryAndSearchesPaths() throws {
        var entries = (0..<70).map {
            RecentProject(path: "/w/Project\($0)", lastOpened: Date(timeIntervalSince1970: Double($0)))
        }
        entries.append(.init(path: "/w/Project0/.", lastOpened: Date(timeIntervalSince1970: 80), isPinned: true))
        entries.append(.init(path: "relative", lastOpened: .now))
        let store = MemoryRecentProjectsStore(projects: entries)
        let model = RecentProjects(store: store, checker: ImmediateFolderChecker())
        #expect(model.projects.count == 51)
        #expect(model.projects.first?.path == "/w/Project0" && model.projects.first?.isPinned == true)
        #expect(model.projects[1].path == "/w/Project69")
        model.query = " /W/PROJECT69 "
        #expect(model.visible.map(\.path) == ["/w/Project69"])
        model.opened(canonicalPath: "/w/Project0", at: Date(timeIntervalSince1970: 100))
        #expect(model.projects.first?.isPinned == true)
        model.pin("/w/Project69", pinned: true)
        #expect(model.projects.first?.path == "/w/Project0")
        #expect(store.projects == model.projects)
    }

    @Test func locateMergesDuplicatesAndRemovalChangesOnlyRecentMetadata() {
        let store = MemoryRecentProjectsStore(projects: [
            .init(path: "/old", lastOpened: .distantPast, isPinned: true),
            .init(path: "/new", lastOpened: .now)
        ])
        let model = RecentProjects(store: store, checker: ImmediateFolderChecker())
        model.setOpenRoots(["/old", "/new"])
        model.opened(canonicalPath: "/new", replacing: "/old")
        #expect(model.projects.count == 1 && model.projects.first?.isPinned == true)
        model.remove("/new")
        #expect(model.projects.isEmpty && store.projects.isEmpty && model.selection == nil)
        #expect(model.openRoots == ["/old", "/new"], "removing Recent is not a close or filesystem operation")
    }

    @Test func focusingAnOpenProjectDoesNotClaimItsMissingFolderIsAvailable() async throws {
        let checker = DelayedFolderChecker()
        let model = RecentProjects(
            store: MemoryRecentProjectsStore(projects: [.init(path: "/w", lastOpened: .distantPast)]),
            checker: checker
        )
        model.refreshAvailability()
        try await waitFor(checker, 1)
        model.checked("/w", state: .unavailable("permission denied"))
        await checker.finish(0, .available(canonicalPath: "/w"))
        try await waitForCompletion(model)
        #expect(model.availability["/w"] == .unavailable("permission denied"))
        model.checked("/w", state: .missing)
        model.opened(canonicalPath: "/w", checked: false)
        #expect(model.availability["/w"] == .missing)
        #expect(model.projects.first?.lastOpened != .distantPast)
    }

    @Test func lateChecksCannotOverwriteAnExplicitOpenOrAReplacedRefresh() async throws {
        let checker = DelayedFolderChecker()
        let model = RecentProjects(
            store: MemoryRecentProjectsStore(projects: [.init(path: "/w", lastOpened: .now)]),
            checker: checker
        )
        #expect(await checker.count == 0, "loading history is passive")
        model.refreshAvailability()
        try await waitFor(checker, 1)
        model.refreshAvailability()
        try await waitFor(checker, 2)
        await checker.finish(0, .missing)
        model.opened(canonicalPath: "/w")
        await checker.finish(1, .missing)
        try await waitForCompletion(model)
        #expect(model.availability["/w"] == .available(canonicalPath: "/w"))
        model.refreshAvailability()
        try await waitFor(checker, 3)
        model.remove("/w")
        await checker.finish(2, .available(canonicalPath: "/w"))
        try await waitForCompletion(model)
        #expect(model.availability["/w"] == nil)
        model.stopChecking()
    }

    @Test func availabilityChecksAreBoundedAndMissingIsNotADeletion() async throws {
        let checker = DelayedFolderChecker()
        let entries = (0..<6).map {
            RecentProject(path: "/w/\($0)", lastOpened: Date(timeIntervalSince1970: Double($0)))
        }
        let model = RecentProjects(store: MemoryRecentProjectsStore(projects: entries), checker: checker)
        model.refreshAvailability()
        try await waitFor(checker, 4)
        #expect(await checker.count == 4)
        await checker.finish(0, .missing)
        try await waitFor(checker, 5)
        let path = await checker.path(0)
        #expect(model.availability[path] == .missing && model.projects.count == 6)
        await checker.finish(1, .unavailable("permission denied"))
        try await waitFor(checker, 6)
        for i in 2..<6 { await checker.finish(i, .missing) }
        model.stopChecking()
        #expect(model.projects.count == 6)
    }

    @Test func persistenceFailureIsVisibleAndDoesNotLoseSessionHistory() {
        let model = RecentProjects(store: FailingRecentStore(), checker: ImmediateFolderChecker())
        #expect(model.storageIssue != nil)
        model.opened(canonicalPath: "/w")
        #expect(model.projects.first?.path == "/w" && model.storageIssue != nil)
    }

    private func waitFor(_ checker: DelayedFolderChecker, _ count: Int) async throws {
        let end = ContinuousClock.now + .seconds(5)
        while await checker.count < count, ContinuousClock.now < end { await Task.yield() }
        try #require(await checker.count >= count)
    }

    private func waitForCompletion(_ model: RecentProjects) async throws {
        let end = ContinuousClock.now + .seconds(5)
        while model.isChecking, ContinuousClock.now < end { await Task.yield() }
        try #require(!model.isChecking)
    }
}

@MainActor
private struct FailingRecentStore: RecentProjectsStore {
    struct Failure: Error {}
    func load() throws -> [RecentProject] { throw Failure() }
    func save(_ projects: [RecentProject]) throws { throw Failure() }
}
