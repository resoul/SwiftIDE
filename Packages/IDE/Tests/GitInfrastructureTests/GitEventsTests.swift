import Foundation
import Testing
import IDEApplication
@testable import GitInfrastructure

@Suite(.serialized) @MainActor
struct GitEventsTests {
    @Test func nestedDiskEditsAreObservedAndStopIsIdempotent() async throws {
        let fixture = try RepositoryFixture(); defer { fixture.remove() }
        try fixture.write("nested/a.txt", "one")
        try fixture.git(["add", "."])
        try fixture.git(["commit", "-m", "One"])
        let repository = try await GitCLI().snapshot(at: fixture.root).repository
        let events = EventCounter()
        let watcher = GitRepositoryEvents(repository: repository) { events.increment() }
        defer { watcher.stop() }
        try await Task.sleep(for: .milliseconds(350))
        try fixture.write("nested/a.txt", "two")
        let deadline = ContinuousClock.now + .seconds(5)
        while events.value == 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(events.value > 0)
        watcher.stop(); watcher.stop()
        let stoppedAt = events.value
        try fixture.write("nested/a.txt", "three")
        try await Task.sleep(for: .milliseconds(600))
        #expect(events.value == stoppedAt)
    }
    @Test func linkedWorktreeObservesReferencesInTheCommonGitDirectory() async throws {
        let fixture = try RepositoryFixture(); defer { fixture.remove() }
        try fixture.write("a.txt", "one"); try fixture.git(["add", "."]); try fixture.git(["commit", "-m", "One"])
        let linked = fixture.root + "-linked"
        defer { try? FileManager.default.removeItem(atPath: linked) }
        try fixture.git(["worktree", "add", "-b", "linked", linked])
        let repository = try await GitCLI().snapshot(at: linked).repository
        #expect(!repository.commonDirectory.hasPrefix(repository.root + "/"))
        let events = EventCounter()
        let watcher = GitRepositoryEvents(repository: repository) { events.increment() }
        defer { watcher.stop() }
        try await Task.sleep(for: .milliseconds(600))
        let previous = events.value
        try fixture.git(["branch", "created-elsewhere"])
        let deadline = ContinuousClock.now + .seconds(5)
        while events.value <= previous, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(events.value > previous)
    }
}

private final class EventCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
