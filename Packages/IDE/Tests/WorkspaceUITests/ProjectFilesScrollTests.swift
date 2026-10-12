import AppKit
import IDEApplication
import Testing
@testable import WorkspaceUI

private actor RefreshableScrollReader: ProjectDirectoryReading {
    private var entries = (0..<200).map { ProjectFile(path: String(format: "/w/%03d.txt", $0), isDirectory: false) }
    private var hold = false
    private var continuation: CheckedContinuation<[ProjectFile], Error>?
    var waiting: Bool { continuation != nil }

    func children(of path: String) async throws -> [ProjectFile] {
        if hold { return try await withCheckedThrowingContinuation { continuation = $0 } }

        return entries
    }

    func pause() { hold = true }

    func finish(_ result: Result<[ProjectFile], Error>? = nil) {
        hold = false
        let response = result ?? .success(entries)
        if case .success(let value) = response { entries = value }
        continuation?.resume(with: response)
        continuation = nil
    }

    func insertAndDelete() {
        entries.removeAll { $0.path == "/w/002.txt" }
        entries.append(.init(path: "/w/000-new.txt", isDirectory: false))
        entries.append(.init(path: "/w/001-new.txt", isDirectory: false))
    }
}

@Suite(.serialized)
@MainActor
struct ProjectFilesScrollTests {
    private func wait(_ predicate: () -> Bool) async throws {
        let end = ContinuousClock.now + .seconds(5)
        while !predicate(), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(1)) }
        try #require(predicate())
    }

    private func settle(_ controller: ProjectFilesViewController) async {
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        controller.view.layoutSubtreeIfNeeded()
    }

    private func window(_ controller: ProjectFilesViewController) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: -2000, y: -2000, width: 460, height: 480),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 460, height: 480))
        window.orderFront(nil)

        return window
    }

    @Test func dirtySelectionGitAndDelayedRefreshRetainScrolledRowsAndActualCells() async throws {
        _ = NSApplication.shared
        let reader = RefreshableScrollReader()
        let model = ProjectFiles(root: "/w", reader: reader)
        let controller = ProjectFilesViewController(model: model)
        let window = window(controller)
        defer {
            controller.disconnect()
            model.stop()
            window.close()
            Task { await reader.finish() }
        }
        try await wait { controller.outline.numberOfRows == 201 }
        controller.view.layoutSubtreeIfNeeded()
        let outline = controller.outline
        let scroll = try #require(outline.enclosingScrollView)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: outline.rect(ofRow: 90).minY + 7))
        scroll.reflectScrolledClipView(scroll.contentView)
        await settle(controller)
        #expect(scroll.contentView.bounds.height > 100)
        let origin = scroll.contentView.bounds.origin
        let item = try #require(outline.item(atRow: 92) as? NSObject)
        let cell = try #require(outline.view(atColumn: 0, row: 92, makeIfNecessary: true) as? FileStatusCell)
        let root = try #require(outline.item(atRow: 0))
        model.select("/w/091.txt")
        model.unsavedPaths = ["/w/091.txt"]
        model.decorations = ["/w/091.txt": .init(worktree: "M")]
        model.statusExplanation = "Git is running…"
        await settle(controller)
        #expect(outline.item(atRow: 92) as? NSObject === item)
        #expect(outline.view(atColumn: 0, row: 92, makeIfNecessary: false) === cell)
        #expect(cell.toolTip?.contains("Unsaved") == true)
        #expect(cell.accessibilityLabel()?.contains("Working tree: M") == true)
        #expect(abs(scroll.contentView.bounds.origin.y - origin.y) < 1)
        var opened: [String] = []
        controller.openFile = { opened.append($0) }
        outline.openSelection?()
        #expect(opened == ["/w/091.txt"])
        await reader.pause()
        model.refresh()
        let end = ContinuousClock.now + .seconds(5)
        while !(await reader.waiting), ContinuousClock.now < end { await Task.yield() }
        try #require(await reader.waiting)
        await settle(controller)
        #expect(model.state(of: "/w") == .loading && outline.numberOfRows == 201)
        #expect(outline.item(atRow: 92) as? NSObject === item)
        #expect(outline.view(atColumn: 0, row: 92, makeIfNecessary: false) === cell)
        #expect(abs(scroll.contentView.bounds.origin.y - origin.y) < 1)
        #expect(outline.isItemExpanded(root))
        await reader.finish()
        try await wait { model.state(of: "/w") == .loaded }
        await settle(controller)
        #expect(outline.view(atColumn: 0, row: 92, makeIfNecessary: false) === cell)
        #expect(abs(scroll.contentView.bounds.origin.y - origin.y) < 1 && outline.numberOfRows == 201)
    }

    @Test func changesAboveViewportKeepFileAnchorAndRefreshFailureKeepsCachedChildren() async throws {
        _ = NSApplication.shared
        let reader = RefreshableScrollReader()
        let model = ProjectFiles(root: "/w", reader: reader)
        let controller = ProjectFilesViewController(model: model)
        let window = window(controller)
        defer {
            controller.disconnect()
            model.stop()
            window.close()
            Task { await reader.finish() }
        }
        try await wait { controller.outline.numberOfRows == 201 }
        controller.view.layoutSubtreeIfNeeded()
        let outline = controller.outline
        let scroll = try #require(outline.enclosingScrollView)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: outline.rect(ofRow: 90).minY + 7))
        scroll.reflectScrolledClipView(scroll.contentView)
        await settle(controller)
        #expect(scroll.contentView.bounds.height > 100)
        let item = try #require(outline.item(atRow: 90) as? NSObject)
        let offset = outline.rect(ofRow: 90).minY - scroll.contentView.bounds.origin.y
        let otherCell = try #require(outline.view(atColumn: 0, row: 92, makeIfNecessary: true))
        let other = try #require(outline.item(atRow: 92))
        await reader.insertAndDelete()
        model.refresh()
        try await wait { model.state(of: "/w") == .loaded && outline.numberOfRows == 202 }
        await settle(controller)
        let index = outline.row(forItem: item)
        #expect(index == 91)
        #expect(abs(outline.rect(ofRow: index).minY - scroll.contentView.bounds.origin.y - offset) < 1)
        #expect(outline.view(atColumn: 0, row: outline.row(forItem: other), makeIfNecessary: false) === otherCell)
        await reader.pause()
        model.refresh()
        let end = ContinuousClock.now + .seconds(5)
        while !(await reader.waiting), ContinuousClock.now < end { await Task.yield() }
        try #require(await reader.waiting)
        await reader.finish(.failure(CocoaError(.fileReadNoPermission)))
        try await wait { model.state(of: "/w") != .loading }
        await settle(controller)
        #expect(outline.numberOfRows == 203, "cached files remain, with an explicit failure row")
        #expect(outline.row(forItem: item) == index)
        #expect(abs(outline.rect(ofRow: index).minY - scroll.contentView.bounds.origin.y - offset) < 1)
        let failure = try #require(outline.item(atRow: 202))
        let failureCell = try #require(controller.outlineView(outline, viewFor: nil, item: failure))
        #expect(failureCell.toolTip?.contains("Could not read folder") == true)
        #expect(outline.view(atColumn: 0, row: outline.row(forItem: other), makeIfNecessary: false) === otherCell)
        model.showExcluded = false
        model.exclude("/w/003.txt")
        await settle(controller)
        #expect(outline.numberOfRows == 202)
        #expect(
            abs(outline.rect(ofRow: outline.row(forItem: item)).minY - scroll.contentView.bounds.origin.y - offset) <
                1
        )
    }
}
