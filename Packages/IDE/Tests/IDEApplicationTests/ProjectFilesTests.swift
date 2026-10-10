import Foundation
import IDEApplication
import Testing

private actor DirectoryScript: ProjectDirectoryReading {
    var calls: [String] = []
    var entries: [String: [ProjectFile]]
    init(_ entries: [String: [ProjectFile]]) { self.entries = entries }
    func children(of path: String) async throws -> [ProjectFile] {
        calls.append(path)

        return entries[path] ?? []
    }
    func set(_ value: [ProjectFile], for path: String) { entries[path] = value }
}

private actor SuspendedDirectories: ProjectDirectoryReading {
    var requests: [(String, CheckedContinuation<[ProjectFile], Error>)] = []
    func children(of path: String) async throws -> [ProjectFile] {
        try await withCheckedThrowingContinuation { requests.append((path, $0)) }
    }
    var count: Int { requests.count }
    func finish(_ index: Int, with result: Result<[ProjectFile], Error>) { requests[index].1.resume(with: result) }
}

@MainActor
private func awaitDirectory(_ model: ProjectFiles, _ path: String) async throws {
    let end = ContinuousClock.now + .seconds(5)
    while model.state(of: path) != .loaded, ContinuousClock.now < end { await Task.yield() }
    try #require(model.state(of: path) == .loaded)
}

private func awaitRequests(_ reader: SuspendedDirectories, _ count: Int) async throws {
    let end = ContinuousClock.now + .seconds(5)
    while await reader.count < count, ContinuousClock.now < end { await Task.yield() }
    try #require(await reader.count == count)
}

@MainActor
struct ProjectFilesTests {
    @Test func expansionIsLazyAndRefreshReadsOnlyExpandedFolders() async throws {
        let reader = DirectoryScript(["/w": [.init(path: "/w/Package.swift", isDirectory: false), .init(path: "/w/.build", isDirectory: true)]])
        let model = ProjectFiles(root: "/w", reader: reader)
        model.expand("/w")
        try await awaitDirectory(model, "/w")
        #expect(await reader.calls == ["/w"], "colouring .build must not enumerate its contents")
        #expect(model.children(of: "/w").map(\.name) == [".build", "Package.swift"])
        #expect(model.decoration(for: "/w/.build").tone == .orange)
        #expect(model.decoration(for: "/w").tone == .normal)
        model.expand("/w/.build")
        try await awaitDirectory(model, "/w/.build")
        #expect(model.exclusionReason(for: "/w/.build/artifacts/x")?.contains("SwiftPM") == true)
        model.collapse("/w/.build")
        model.refresh()
        try await awaitDirectory(model, "/w")
        #expect(await reader.calls == ["/w", "/w/.build", "/w"])
        model.stop()
    }

    @Test func ordinaryBuildAndBackupAreNotExcluded() async throws {
        let reader = DirectoryScript(["/w": [.init(path: "/w/build", isDirectory: true), .init(path: "/w/.build", isDirectory: true), .init(path: "/w/x.bak", isDirectory: false)]])
        let model = ProjectFiles(root: "/w", reader: reader)
        model.expand("/w")
        try await awaitDirectory(model, "/w")
        #expect(model.children(of: "/w").allSatisfy { model.exclusionReason(for: $0.path) == nil })
        await reader.set([.init(path: "/w/Package.swift", isDirectory: false), .init(path: "/w/.build", isDirectory: true)], for: "/w")
        model.refresh()
        try await awaitDirectory(model, "/w")
        model.include("/w/.build/child")
        #expect(model.exclusionReason(for: "/w/.build") == nil)
        #expect(model.exclusions.includedDefaults == [".build"])
        model.refresh()
        try await awaitDirectory(model, "/w")
        #expect(model.exclusionReason(for: "/w/.build") == nil, "refresh must preserve user inclusion")
    }

    @Test func nestedPackageDefaultsFollowTheirActualFolderAndDisappearWithTheMarker() async throws {
        let reader = DirectoryScript(["/w/P": [.init(path: "/w/P/Package.swift", isDirectory: false), .init(path: "/w/P/.build", isDirectory: true)]])
        let model = ProjectFiles(root: "/w", reader: reader)
        model.expand("/w/P")
        try await awaitDirectory(model, "/w/P")
        #expect(model.exclusionReason(for: "/w/P/.build") != nil)
        #expect(model.exclusionReason(for: "/w/.build") == nil)
        await reader.set([.init(path: "/w/P/.build", isDirectory: true)], for: "/w/P")
        model.refresh()
        try await awaitDirectory(model, "/w/P")
        #expect(model.exclusionReason(for: "/w/P/.build") == nil)
    }

    @Test func projectAndIgnoreFiltersAreIndependentAndSelectionSurvives() async throws {
        let reader = DirectoryScript(["/w": ["excluded", "ignored", "plain"].map { .init(path: "/w/" + $0, isDirectory: false) }])
        let model = ProjectFiles(root: "/w", reader: reader)
        model.expand("/w")
        try await awaitDirectory(model, "/w")
        model.exclude("/w/excluded")
        model.decorations = ["/w/ignored": .init(ignoredReason: ".gitignore:2")]
        model.select("/w/plain")
        model.showExcluded = false
        #expect(model.children(of: "/w").map(\.name) == ["ignored", "plain"])
        model.showIgnored = false
        #expect(model.children(of: "/w").map(\.name) == ["plain"])
        model.showExcluded = true
        #expect(model.children(of: "/w").map(\.name) == ["excluded", "plain"])
        model.refresh()
        try await awaitDirectory(model, "/w")
        #expect(model.selection == "/w/plain")
        #expect(!model.statusExplanation.isEmpty)
    }

    @Test func exclusionsHavePathBoundariesAndDoNotBlockExplicitOpening() {
        let model = ProjectFiles(root: "/w", reader: DirectoryScript([:]))
        model.exclude("/w/Sources")
        model.exclude("/outside")
        model.exclude("/w")
        #expect(model.exclusions.explicit == ["Sources"])
        #expect(model.exclusionReason(for: "/w/Sources/a.swift") != nil)
        #expect(model.exclusionReason(for: "/w/SourcesOther/a.swift") == nil)
        #expect(model.exclusionRoot(for: "/w/Sources/deeper/a") == "/w/Sources")
        model.include("/w/Sources/deeper/a")
        #expect(model.exclusionReason(for: "/w/Sources") == nil)
    }

    @Test func aliasDirtyStateUsesResolvedIdentityWithoutAFileSystemReadInPresentation() async throws {
        let model = ProjectFiles(root: "/w", reader: DirectoryScript(["/w": [.init(path: "/w/link.txt", isDirectory: false, isSymbolicLink: true, resolvedPath: "/other/a.txt")]]))
        model.expand("/w")
        try await awaitDirectory(model, "/w")
        model.unsavedPaths = ["/other/a.txt"]
        #expect(model.decoration(for: "/w/link.txt").isUnsaved)
    }

    @Test func duplicateAndNonDirectChildrenFromAnAdapterAreRefused() async throws {
        let file = ProjectFile(path: "/w/a", isDirectory: false)
        let model = ProjectFiles(root: "/w", reader: DirectoryScript(["/w": [file, file, .init(path: "/outside/a", isDirectory: false), .init(path: "/w/d/deep", isDirectory: false)]]))
        model.expand("/outside")
        #expect(model.expanded.isEmpty)
        model.expand("/w")
        try await awaitDirectory(model, "/w")
        #expect(model.children(of: "/w") == [file])
    }

    @Test func cancelledAndReplacedRequestsCannotPublishOldDataAndFailureIsHonest() async throws {
        let reader = SuspendedDirectories()
        let model = ProjectFiles(root: "/w", reader: reader)
        model.expand("/w")
        model.expand("/w")
        try await awaitRequests(reader, 1)
        model.collapse("/w")
        #expect(model.state(of: "/w") == .cancelled)
        model.expand("/w")
        try await awaitRequests(reader, 2)
        await reader.finish(1, with: .success([.init(path: "/w/new", isDirectory: false)]))
        try await awaitDirectory(model, "/w")
        await reader.finish(0, with: .failure(CocoaError(.fileReadUnknown)))
        for _ in 0..<10 { await Task.yield() }
        #expect(model.state(of: "/w") == .loaded, "a late failure cannot replace the newer successful result")
        #expect(model.children(of: "/w").map(\.name) == ["new"])
        model.refresh()
        try await awaitRequests(reader, 3)
        await reader.finish(2, with: .failure(CocoaError(.fileReadNoPermission)))
        let end = ContinuousClock.now + .seconds(5)
        while model.state(of: "/w") == .loading, ContinuousClock.now < end { await Task.yield() }
        guard case .failed = model.state(of: "/w") else { Issue.record("failure must not look like an empty loaded folder"); return }

        #expect(model.state(of: "/w").message?.contains("Could not read folder") == true)
        model.stop()
    }
}
