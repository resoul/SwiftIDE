import AppKit
import IDEApplication
import Testing
@testable import WorkspaceUI

private struct UITreeReader: ProjectDirectoryReading {
    func children(of path: String) async throws -> [ProjectFile] {
        path == "/w" ? [.init(path: "/w/a.txt", isDirectory: false), .init(path: "/w/build", isDirectory: true)] : []
    }
}

@Suite(.serialized)
@MainActor
struct ProjectFilesUITests {
    private func loaded(_ model: ProjectFiles) async throws {
        let end = ContinuousClock.now + .seconds(5)
        while model.state(of: "/w") != .loaded, ContinuousClock.now < end { await Task.yield() }
        try #require(model.state(of: "/w") == .loaded)
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
        try await loaded(model)
        model.select("/w/a.txt")
        #expect(first.outline.selectedRow >= 0 && second.outline.selectedRow >= 0)
        model.refresh()
        try await loaded(model)
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
        try await loaded(model)
        model.exclude("/w/a.txt")
        model.decorations = ["/w/a.txt": .init(index: "A", worktree: "M", isConflict: true)]
        model.unsavedPaths = ["/w/a.txt"]
        model.select("/w/a.txt")
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
