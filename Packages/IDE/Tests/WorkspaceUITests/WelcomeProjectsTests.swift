import AppKit
import IDEApplication
import Testing
@testable import WorkspaceUI

@MainActor
private final class WelcomeStore: RecentProjectsStore {
    var entries: [RecentProject] = []
    func load() throws -> [RecentProject] { entries }
    func save(_ projects: [RecentProject]) throws { entries = projects }
}
private struct WelcomeChecker: ProjectFolderChecking {
    func check(path: String) async -> ProjectFolderAvailability {
        path.contains("missing") ? .missing : .available(canonicalPath: path)
    }
}

@Suite(.serialized)
@MainActor
struct WelcomeProjectsTests {
    @Test func searchingAndBackgroundUpdatesPreserveInputAndReturnOpensTheSelectedProject() async throws {
        _ = NSApplication.shared
        let store = WelcomeStore()
        store.entries = [.init(path: "/work/Alpha", lastOpened: .now), .init(path: "/work/Beta", lastOpened: .distantPast)]
        let model = RecentProjects(store: store, checker: WelcomeChecker())
        let controller = WelcomeProjectsViewController(model: model, version: "Test build")
        let window = makeWindow(controller)
        defer { controller.disconnect(); model.stopChecking(); window.close() }
        controller.focusSearch()
        let responder = window.firstResponder
        controller.search.stringValue = "beta"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        #expect(controller.table.numberOfRows == 1)
        #expect(controller.table.selectedRow == 0)
        model.refreshAvailability()
        let end = ContinuousClock.now + .seconds(5)
        while model.isChecking, ContinuousClock.now < end { await Task.yield() }
        #expect(window.firstResponder === responder)
        #expect(controller.search.stringValue == "beta")
        var opened: [String] = []
        controller.openProject = { opened.append($0) }
        #expect(controller.search.sendAction(controller.search.action, to: controller.search.target))
        #expect(opened == ["/work/Beta"])
        opened.removeAll()
        controller.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        controller.table.keyDown(with: event)
        #expect(opened == ["/work/Beta"])
        let menu = NSMenu()
        controller.menuNeedsUpdate(menu)
        #expect(menu.items.map(\.title) == ["Open", "Pin", "Locate Folder…", "Remove from Recent"])
        menu.performActionForItem(at: 1)
        #expect(model.projects.first?.path == "/work/Beta" && model.projects.first?.isPinned == true)
        menu.performActionForItem(at: 3)
        #expect(model.projects.map(\.path) == ["/work/Alpha"] && controller.table.numberOfRows == 0)
        #expect(window.firstResponder === responder)
    }

    @Test func emptyAndMissingStatesAreAccessibleAndRenderInBothThemes() async throws {
        _ = NSApplication.shared
        let store = WelcomeStore()
        let model = RecentProjects(store: store, checker: WelcomeChecker())
        let controller = WelcomeProjectsViewController(model: model, version: "Test build")
        let window = makeWindow(controller)
        defer { controller.disconnect(); model.stopChecking(); window.close() }
        #expect(controller.table.numberOfRows == 0)
        #expect(descendants(controller.view).compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("Welcome to SwiftIDE") })
        if ProcessInfo.processInfo.environment["SWIFTIDE_RENDER_WELCOME"] == "1" { try render(window, name: "empty") }
        model.opened(canonicalPath: "/projects/SwiftIDE")
        model.opened(canonicalPath: "/projects/missing")
        model.pin("/projects/SwiftIDE", pinned: true)
        model.setOpenRoots(["/projects/SwiftIDE"])
        model.refreshAvailability()
        let end = ContinuousClock.now + .seconds(5)
        while model.isChecking, ContinuousClock.now < end { await Task.yield() }
        try #require(!model.isChecking)
        let cell = try #require(controller.tableView(controller.table, viewFor: nil, row: 1) as? WelcomeProjectCell)
        #expect(cell.accessibilityLabel()?.contains("Folder not found") == true)
        #expect(cell.toolTip?.contains("Locate or remove") == true)
        let first = try #require(controller.tableView(controller.table, viewFor: nil, row: 0) as? WelcomeProjectCell)
        #expect(first.accessibilityLabel()?.contains("Pinned") == true && first.accessibilityLabel()?.contains("Open") == true)
        for theme in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: theme)
            controller.view.layoutSubtreeIfNeeded()
            #expect(controller.search.bounds.width > 120)
            #expect(controller.table.bounds.width > 300)
            try assertSelectedTitleContrast(controller)
        }
        window.setContentSize(NSSize(width: 760, height: 480))
        controller.view.layoutSubtreeIfNeeded()
        #expect(controller.search.bounds.width > 100)
        if ProcessInfo.processInfo.environment["SWIFTIDE_RENDER_WELCOME"] == "1" { try render(window, name: "recent") }
    }

    private func makeWindow(_ content: NSViewController) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -2000, y: -2000, width: 900, height: 640), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = content

        return window
    }
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    private func assertSelectedTitleContrast(_ controller: WelcomeProjectsViewController) throws {
        let view = controller.view
        view.displayIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let rect = controller.table.rect(ofRow: controller.table.selectedRow)
        let point = controller.table.convert(NSPoint(x: rect.maxX - 12, y: rect.midY), to: view)
        let background = try #require(bitmap.colorAt(x: Int(point.x), y: Int(view.bounds.height - point.y))?.usingColorSpace(.deviceRGB))
        let title = try #require(descendants(controller.table).compactMap { $0 as? NSTextField }.first { $0.stringValue == "missing" })
        var foreground: NSColor?
        title.effectiveAppearance.performAsCurrentDrawingAppearance { foreground = title.textColor?.usingColorSpace(.deviceRGB) }
        let a = luminance(try #require(foreground))
        let b = luminance(background)
        #expect((max(a, b) + 0.05) / (min(a, b) + 0.05) >= 4.5, "selected project titles remain readable in both appearances")
    }

    private func luminance(_ colour: NSColor) -> CGFloat {
        func linear(_ value: CGFloat) -> CGFloat { value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }

        return 0.2126 * linear(colour.redComponent) + 0.7152 * linear(colour.greenComponent) + 0.0722 * linear(colour.blueComponent)
    }

    private func render(_ window: NSWindow, name: String) throws {
        for (label, theme) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            window.appearance = NSAppearance(named: theme)
            let view = try #require(window.contentView)
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/private/tmp/swiftide-welcome-\(name)-\(label).png"))
        }
    }
}
