import Foundation
import IDEApplication
import IDEDomain
import IDETestSupport
import Testing

private final class FakeItems: ProjectItemOperating, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [String] = []
    var recorded: [String] { lock.withLock { calls } }
    var failure: NewEntryError?

    func rename(_ path: String, to name: String) throws -> String {
        lock.withLock { calls.append("rename \(path) \(name)") }
        if let failure { throw failure }

        return (path as NSString).deletingLastPathComponent + "/" + name
    }

    func duplicate(_ path: String, as name: String) throws -> String {
        lock.withLock { calls.append("duplicate \(path) \(name)") }

        return (path as NSString).deletingLastPathComponent + "/" + name
    }

    func trash(_ path: String) throws { lock.withLock { calls.append("trash \(path)") } }

    func move(_ path: String, into directory: String) throws -> String {
        lock.withLock { calls.append("move \(path) \(directory)") }
        if let failure { throw failure }

        return directory + "/" + (path as NSString).lastPathComponent
    }

    func copy(_ path: String, into directory: String) throws -> String {
        lock.withLock { calls.append("copy \(path) \(directory)") }
        if let failure { throw failure }

        return directory + "/" + (path as NSString).lastPathComponent
    }
}

private struct EmptyReader: ProjectDirectoryReading {
    func children(of path: String) async throws -> [ProjectFile] { [] }
}

@MainActor
private func makeModel(_ items: FakeItems, exclusions: ProjectExclusions = .init()) -> ProjectFiles {
    ProjectFiles(root: "/w", reader: EmptyReader(), exclusions: exclusions, operations: items)
}

@Test @MainActor
func renamingMovesTheTreesStateAndExclusionsAndTellsTheOwner() throws {
    let items = FakeItems()
    let model = makeModel(items, exclusions: ProjectExclusions(explicit: ["Old/gen", "Other"]))
    var excluded: [Set<String>] = []
    model.onExclusionsChange = { excluded.append($0.explicit) }
    var renamed: [(String, String)] = []
    model.onItemRenamed = { renamed.append(($0, $1)) }
    model.expand("/w/Old")
    model.expand("/w/Old/sub")
    model.select("/w/Old/sub/file.swift")
    #expect(try model.rename("/w/Old", to: "New") == "/w/New")
    #expect(model.expanded.contains("/w/New") && model.expanded.contains("/w/New/sub") && !model.expanded
        .contains("/w/Old"))
    #expect(model.selection == "/w/New")
    #expect(model.exclusions.explicit == ["New/gen", "Other"] && excluded == [["New/gen", "Other"]])
    #expect(renamed.map(\.0) == ["/w/Old"] && renamed.map(\.1) == ["/w/New"])
    #expect(items.recorded == ["rename /w/Old New"])
    model.stop()
}

@Test @MainActor
func aRefusalChangesNothingAndABlockedProjectDoesNotTouchTheDisk() throws {
    let items = FakeItems()
    let model = makeModel(items)
    var called = false
    model.onItemRenamed = { _, _ in called = true }
    items.failure = .alreadyExists("x")
    #expect(throws: NewEntryError.alreadyExists("x")) { try model.rename("/w/a.txt", to: "x") }
    #expect(!called)
    model.blockedReason = { "A Git operation is running." }
    #expect(throws: NewEntryError.failed("A Git operation is running.")) { try model.rename("/w/a.txt", to: "y") }
    #expect(throws: NewEntryError.failed("A Git operation is running.")) { try model.trash("/w/a.txt") }
    #expect(throws: NewEntryError.isProjectFolder) { try model.rename("/w", to: "z") }
    #expect(throws: NewEntryError.isProjectFolder) { try model.trash("/w") }
    #expect(items.recorded == ["rename /w/a.txt x"])
    #expect(throws: NewEntryError.self) { try ProjectFiles(root: "/w", reader: EmptyReader()).trash("/w/a") }
}

@Test @MainActor
func duplicateSelectsTheCopyAndTrashForgetsTheItemAndTellsTheOwner() throws {
    let items = FakeItems()
    let model = makeModel(items, exclusions: ProjectExclusions(explicit: ["dir/inner", "keep"]))
    var trashed: [String] = []
    model.onItemTrashed = { trashed.append($0) }
    #expect(try model.duplicate("/w/a.txt", as: "a copy.txt") == "/w/a copy.txt" && model.selection == "/w/a copy.txt")
    model.expand("/w/dir")
    model.select("/w/dir/x.txt")
    try model.trash("/w/dir")
    #expect(trashed == ["/w/dir"] && !model.expanded.contains("/w/dir") && model.selection == "/w")
    #expect(model.exclusions.explicit == ["keep"])
    #expect(items.recorded == ["duplicate /w/a.txt a copy.txt", "trash /w/dir"])
    model.stop()
}

@Test @MainActor
func unsavedChangesUnderAnItemAreCounted() {
    let model = makeModel(FakeItems())
    model.unsavedPaths = ["/w/dir/a.swift", "/w/dir/sub/b.swift", "/w/directory/c.swift", "/w/z.swift"]
    #expect(model.unsavedCount(under: "/w/dir") == 2)
    #expect(model.unsavedCount(under: "/w/z.swift") == 1 && model.unsavedCount(under: "/w/none") == 0)
}

@Test @MainActor
func aRenamedDocumentKeepsItsTextAndUnsavedStateAndTellsTheWatchers() {
    let session = DocumentSession(path: "/w/Old.swift", backend: StringDocumentBackend(loadedText: "let a = 1"))
    var notified = 0
    session.subscribeToSaves { notified += 1 }
    let before = session.version
    session.acknowledgeRename(to: "/w/New.swift")
    #expect(session.path == "/w/New.swift" && session.version == before && notified == 1)
    session.acknowledgeRename(to: "/w/New.swift")
    #expect(notified == 1, "the same name is nothing to tell")
    let untitled = DocumentSession(path: "Untitled", backend: StringDocumentBackend(loadedText: ""), isUntitled: true)
    untitled.acknowledgeRename(to: "/w/x.swift")
    #expect(untitled.path == "Untitled")
}

@Test @MainActor
func movingSeveralItemsRetargetsEachOneStopsAtTheFirstFailureAndKeepsWhatWasDone() {
    let items = FakeItems()
    let model = makeModel(items, exclusions: ProjectExclusions(explicit: ["a.txt"]))
    var renamed: [String] = []
    model.onItemRenamed = { renamed.append("\($0)>\($1)") }
    let done = model.move(["/w/a.txt", "/w/b.txt"], into: "/w/dir")
    #expect(done.done == ["/w/dir/a.txt", "/w/dir/b.txt"] && done.failure == nil)
    #expect(renamed == ["/w/a.txt>/w/dir/a.txt", "/w/b.txt>/w/dir/b.txt"])
    #expect(model.exclusions.explicit == ["dir/a.txt"] && model.selection == "/w/dir/a.txt")
    items.failure = .alreadyExists("c.txt")
    let partial = model.move(["/w/c.txt", "/w/d.txt"], into: "/w/dir")
    #expect(partial.done.isEmpty && partial.failure == .alreadyExists("c.txt"))
    #expect(items.recorded.filter { $0.hasPrefix("move") }.count == 3, "stopped at the first failure")
    model.stop()
}

@Test @MainActor
func anItemAlreadyInTheFolderIsNotRetargetedAndCopiesNeedNoDocumentsToFollow() {
    let model = makeModel(FakeItems())
    var renamed = 0
    model.onItemRenamed = { _, _ in renamed += 1 }
    let stay = model.move(["/w/dir/a.txt"], into: "/w/dir")
    #expect(stay.done == ["/w/dir/a.txt"] && renamed == 0, "a path that did not change tells nobody")
    let copied = model.copy(["/elsewhere/x.txt"], into: "/w/dir")
    #expect(copied.done == ["/w/dir/x.txt"] && renamed == 0)
    #expect(model.move(["/w/a.txt"], into: "/outside").failure == .outsideProject)
    #expect(model.copy(["/elsewhere/y.txt"], into: "/outside").failure == .outsideProject)
    #expect(model.move(["/w"], into: "/w/dir").failure == .isProjectFolder)
    model.stop()
}

@Test @MainActor
func aBlockedProjectRefusesMovesAndCopiesWithoutTouchingTheDisk() {
    let items = FakeItems()
    let model = makeModel(items)
    model.blockedReason = { "A Git operation is running." }
    #expect(model.copy(["/elsewhere/y.txt"], into: "/w/dir").failure == .failed("A Git operation is running."))
    #expect(model.move(["/w/a.txt"], into: "/w/dir").failure == .failed("A Git operation is running."))
    #expect(items.recorded.isEmpty)
    model.stop()
}
