import AppKit
import IDEApplication
import Testing
@testable import WorkspaceUI

private struct UITreeReader: ProjectDirectoryReading {
    func children(of path: String) async throws -> [ProjectFile] {
        path == "/w" ? [.init(path: "/w/a.txt", isDirectory: false), .init(path: "/w/build", isDirectory: true)] : []
    }
}

private struct NestedUITreeReader: ProjectDirectoryReading {
    func children(of path: String) async throws -> [ProjectFile] {
        switch path {
        case "/w": [.init(path: "/w/folder", isDirectory: true)]
        case "/w/folder": [.init(path: "/w/folder/nested", isDirectory: true), .init(path: "/w/folder/other.txt", isDirectory: false)]
        default: (0..<20).map { .init(path: path + "/\($0).txt", isDirectory: false) }
        }
    }
}

private actor HeldUITreeReader: ProjectDirectoryReading {
    private var continuation: CheckedContinuation<[ProjectFile], Never>?
    func children(of path: String) async throws -> [ProjectFile] {
        if path == "/w" { return [.init(path: "/w/folder", isDirectory: true)] }

        return await withCheckedContinuation { continuation = $0 }
    }
    var waiting: Bool { continuation != nil }
    func finish() { continuation?.resume(returning: [.init(path: "/w/folder/late.txt", isDirectory: false)]); continuation = nil }
}

@Suite(.serialized)
@MainActor
struct ProjectFilesUITests {
    private func waitFor(_ condition: () -> Bool) async throws {
        let end = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(1)) }
        try #require(condition())
    }

    private func loaded(_ model: ProjectFiles, in controllers: ProjectFilesViewController...) async throws {
        try await waitFor {
            model.state(of: "/w") == .loaded && controllers.allSatisfy { controller in
                guard let file = model.children(of: "/w").first, let item = controller.outline.item(atRow: 1) else { return false }

                return controller.outline.numberOfRows == model.children(of: "/w").count + 1
                    && controller.outlineView(controller.outline, viewFor: nil, item: item)?.toolTip?.hasPrefix(file.path) == true
            }
        }
    }

    @Test func collapsingAnExpandedFolderWithExpandedChildrenKeepsTheNativeOutlineValid() async throws {
        _ = NSApplication.shared
        let model = ProjectFiles(root: "/w", reader: NestedUITreeReader())
        let controller = ProjectFilesViewController(model: model)
        let window = NSWindow(contentRect: NSRect(x: -2000, y: -2000, width: 460, height: 600), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        defer { controller.disconnect(); model.stop(); window.close() }
        try await loaded(model, in: controller)
        let root = try #require(controller.outline.item(atRow: 0))
        let folder = try #require(controller.outline.item(atRow: 1))
        controller.outline.expandItem(folder)
        try await waitFor { model.state(of: "/w/folder") == .loaded && controller.outline.numberOfRows == 4 }
        let nested = try #require(controller.outline.item(atRow: 2))
        controller.outline.expandItem(nested)
        try await waitFor { model.state(of: "/w/folder/nested") == .loaded && controller.outline.numberOfRows == 24 }
        for cycle in 0..<30 {
            controller.outline.collapseItem(folder, collapseChildren: cycle.isMultiple(of: 2))
            await nextMainQueueTurn()
            #expect(!model.expanded.contains("/w/folder"))
            #expect(!controller.outline.isItemExpanded(folder))
            #expect(controller.outline.numberOfRows == 2)
            controller.outline.expandItem(folder)
            controller.outline.expandItem(nested)
            await nextMainQueueTurn()
            #expect(controller.outline.numberOfRows == 24)
        }
        controller.outline.collapseItem(root, collapseChildren: true)
        await nextMainQueueTurn()
        try await waitFor { controller.outline.numberOfRows == 1 }
        #expect(controller.outline.numberOfRows == 1)
        #expect(!model.expanded.contains(model.root))
    }

    @Test func loadingItemsKeepTheirIdentityAndDisconnectCancelsTheQueuedReload() async throws {
        _ = NSApplication.shared
        let reader = HeldUITreeReader()
        let model = ProjectFiles(root: "/w", reader: reader)
        let controller = ProjectFilesViewController(model: model)
        _ = controller.view
        defer { controller.disconnect(); model.stop(); Task { await reader.finish() } }
        try await loaded(model, in: controller)
        let folder = try #require(controller.outline.item(atRow: 1))
        controller.outline.expandItem(folder)
        let end = ContinuousClock.now + .seconds(5)
        while !(await reader.waiting), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(1)) }
        try #require(await reader.waiting)
        await nextMainQueueTurn()
        let firstItem = controller.outlineView(controller.outline, child: 0, ofItem: folder) as? NSObject
        let secondItem = controller.outlineView(controller.outline, child: 0, ofItem: folder) as? NSObject
        let first = try #require(firstItem)
        let again = try #require(secondItem)
        #expect(first === again, "AppKit's placeholder item must be a retained stable object")
        let childCount = controller.outlineView(controller.outline, numberOfChildrenOfItem: first)
        #expect(childCount == 0)
        controller.outline.collapseItem(folder)
        #expect(model.state(of: "/w/folder") == .cancelled)
        let duringUpdate = controller.outlineView(controller.outline, child: 0, ofItem: folder) as? NSObject
        #expect(duringUpdate === first, "model changes must not replace data-source items inside the native operation")
        controller.disconnect()
        await nextMainQueueTurn()
        let afterDisconnect = controller.outlineView(controller.outline, child: 0, ofItem: folder) as? NSObject
        #expect(afterDisconnect === first)
        await reader.finish()
        await nextMainQueueTurn()
        #expect(model.state(of: "/w/folder") == .cancelled)
        #expect(model.children(of: "/w/folder").isEmpty && controller.outline.numberOfRows == 2)
    }

    private func nextMainQueueTurn() async {
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    }

    @Test func twoViewsShareSelectionAndExpansionWithoutOpeningOnBackgroundRefresh() async throws {
        _ = NSApplication.shared
        let model = ProjectFiles(root: "/w", reader: UITreeReader())
        let first = ProjectFilesViewController(model: model), second = ProjectFilesViewController(model: model)
        _ = first.view
        _ = second.view
        defer { first.disconnect(); second.disconnect(); model.stop() }
        var opened: [String] = []
        first.openFile = { opened.append($0) }
        try await loaded(model, in: first, second)
        model.select("/w/a.txt")
        try await waitFor { first.outline.selectedRow >= 0 && second.outline.selectedRow >= 0 }
        #expect(first.outline.selectedRow >= 0 && second.outline.selectedRow >= 0)
        model.refresh()
        try await loaded(model, in: first, second)
        try await waitFor { first.outline.selectedRow >= 0 && second.outline.selectedRow >= 0 }
        #expect(model.selection == "/w/a.txt" && opened.isEmpty)
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        first.outline.keyDown(with: event)
        #expect(opened == ["/w/a.txt"])
    }

    @Test func statusAndExclusionAreAccessibleAndSelectedRowsKeepReadableBadges() async throws {
        _ = NSApplication.shared
        let model = ProjectFiles(root: "/w", reader: UITreeReader())
        let controller = ProjectFilesViewController(model: model)
        _ = controller.view
        defer { controller.disconnect(); model.stop() }
        try await loaded(model, in: controller)
        model.exclude("/w/a.txt")
        model.decorations = ["/w/a.txt": .init(index: "A", worktree: "M", isConflict: true)]
        model.unsavedPaths = ["/w/a.txt"]
        model.select("/w/a.txt")
        try await waitFor { controller.outline.selectedRow >= 0 }
        let item = try #require(controller.outline.item(atRow: controller.outline.selectedRow))
        let cell = try #require(controller.outlineView(controller.outline, viewFor: nil, item: item) as? FileStatusCell)
        #expect(cell.textField?.textColor == .systemOrange)
        #expect(cell.toolTip?.contains("Index: A") == true && cell.toolTip?.contains("Working tree: M") == true)
        #expect(cell.accessibilityLabel()?.contains("Conflict") == true)
        #expect(cell.accessibilityLabel()?.contains("Unsaved editor changes") == true)
        cell.backgroundStyle = .emphasized
        #expect(cell.textField?.textColor == .alternateSelectedControlTextColor)
        cell.backgroundStyle = .normal
        #expect(cell.textField?.textColor == .systemOrange)
        let menu = NSMenu()
        controller.menuNeedsUpdate(menu)
        #expect(menu.items.contains { $0.title == "Reveal in Finder" })
        #expect(menu.items.first { $0.title == "Show Ignored" }?.isEnabled == false)
        model.hasIgnoreInformation = true
        controller.menuNeedsUpdate(menu)
        #expect(menu.items.first { $0.title == "Show Ignored" }?.isEnabled == true)
    }

    @Test func nativeTabsSelectTheOriginalWindowAndKeepDirtyStatusSeparateFromGit() throws {
        _ = NSApplication.shared
        let a = NSWindow(contentRect: NSRect(x: -2000, y: -2000, width: 600, height: 400), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        let b = NSWindow(contentRect: a.frame, styleMask: a.styleMask, backing: .buffered, defer: false)
        a.isReleasedWhenClosed = false
        b.isReleasedWhenClosed = false
        defer { a.close(); b.close() }
        let root = "/w/\(UUID())"
        ProjectDocumentTabs.configure(a, root: root)
        ProjectDocumentTabs.configure(b, root: root)
        a.orderFront(nil)
        ProjectDocumentTabs.append(b, to: a)
        #expect(a.tabGroup === b.tabGroup)
        #expect(a.tabGroup?.windows.count == 2)
        #expect(a.tabGroup?.selectedWindow === b)
        ProjectDocumentTabs.select(a)
        #expect(a.tabGroup?.selectedWindow === a)
        ProjectDocumentTabs.present(.init(index: "A", worktree: "M", exclusionReason: "excluded", isUnsaved: true), name: "a.txt", path: "/w/a.txt", in: a)
        #expect(a.tab.title == "a.txt  A M ●")
        #expect(a.tab.toolTip.contains("Unsaved editor changes"))
        #expect(a.tab.attributedTitle?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == .systemOrange)
    }
}
