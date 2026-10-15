import AppKit
import IDEApplication
import Testing
@testable import WorkspaceUI

@Suite(.serialized)
@MainActor
struct WorkspaceViewTests {
    @Test func nativeToolbarAlignsWindowControlsAndRetainsProjectActions() throws {
        _ = NSApplication.shared
        let state = WorkspaceLayoutState()
        let workspace = WorkspaceViewController(
            state: state,
            editor: NSView(),
            panels: [.files: .init(view: NSView())],
            project: "SwiftIDE",
            path: "/preview/SwiftIDE"
        )
        let window = NSWindow(
            contentRect: NSRect(x: -2000, y: -2000, width: 1280, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.titleVisibility = .hidden
        window.contentViewController = workspace
        defer {
            workspace.disconnect()
            window.close()
        }
        let originalHeight = window.frame.height - window.contentLayoutRect.height
        workspace.installWindowToolbar(on: window)
        let branch = NSButton(title: "main", target: nil, action: nil)
        workspace.installProjectAccessory(branch)
        workspace.present(detail: "Plain Text", status: nil)
        window.contentView?.superview?.layoutSubtreeIfNeeded()
        workspace.view.layoutSubtreeIfNeeded()
        let toolbar = try #require(window.toolbar)
        #expect(window.toolbarStyle == .unified)
        #expect(window.frame.height - window.contentLayoutRect.height > originalHeight + 8)
        let project = try #require(toolbar.items.first { $0.itemIdentifier == WorkspaceWindowToolbar.project }?.view)
        let close = try #require(window.standardWindowButton(.closeButton))
        let projectRect = project.convert(project.bounds, to: nil)
        let closeRect = close.convert(close.bounds, to: nil)
        #expect(abs(projectRect.midY - closeRect.midY) < 3)
        let editorRect = workspace.horizontal.view.convert(workspace.horizontal.view.bounds, to: nil)
        #expect(editorRect.maxY <= window.contentLayoutRect.maxY)
        #expect(branch.isDescendant(of: project))
        let focus = try #require(
            toolbar.items.first { $0.itemIdentifier == WorkspaceWindowToolbar.focus }?.view as? NSButton
        )
        focus.performClick(nil)
        #expect(state.isFocused && !toolbar.isVisible)
        workspace.toggleFocusEditor(nil)
        #expect(!state.isFocused && toolbar.isVisible)
        let reset = try #require(
            toolbar.items.first { $0.itemIdentifier == WorkspaceWindowToolbar.reset }?.view as? NSButton
        )
        state.select(.files)
        reset.performClick(nil)
        #expect(state.layout.left == .files)
        if ProcessInfo.processInfo.environment["SWIFTIDE_RENDER_SHELL"] == "1" {
            window.appearance = NSAppearance(named: .darkAqua)
            let frame = try #require(window.contentView?.superview)
            frame.layoutSubtreeIfNeeded()
            let bitmap = try #require(frame.bitmapImageRepForCachingDisplay(in: frame.bounds))
            frame.cacheDisplay(in: frame.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: "/private/tmp/swiftide-native-toolbar.png"))
        }
    }

    @Test func rootViewRoutesRailAndPanelButtonsToTheCurrentTool() throws {
        _ = NSApplication.shared
        let custom = WorkspaceTool(id: 101, title: "Custom", symbol: "folder", zone: .left)
        let state = WorkspaceLayoutState(available: [.files, custom])
        let editor = NSTextView()
        editor.string = "Original editor"
        let draft = NSTextField(string: "Keep this draft")
        let workspace = WorkspaceViewController(
            state: state,
            editor: editor,
            panels: [.files: .init(view: NSView()), custom: .init(view: draft)],
            project: "Preview",
            path: "/preview"
        )
        defer { workspace.disconnect() }
        let root = try #require(workspace.view as? WorkspaceView)
        #expect(workspace.vertical.parent === workspace)
        #expect(workspace.horizontal.parent === workspace.vertical)
        #expect(workspace.vertical.view.isDescendant(of: root))
        let customButton = try #require(workspace.buttons[custom])
        customButton.performClick(nil)
        #expect(state.layout.left == custom)
        #expect(draft.isDescendant(of: root))
        let closeCustom = try #require(hideButton(in: root.leftSurface))
        closeCustom.performClick(nil)
        #expect(state.layout.left == nil)
        workspace.buttons[.files]?.performClick(nil)
        #expect(state.layout.left == .files)
        let closeFiles = try #require(hideButton(in: root.leftSurface))
        closeFiles.performClick(nil)
        #expect(state.layout.left == nil, "the panel's hide button follows the newly selected tool")
        customButton.performClick(nil)
        #expect(state.layout.left == custom && draft.stringValue == "Keep this draft")
        #expect(workspace.view === root && editor.isDescendant(of: root))
        #expect(editor.string == "Original editor")
    }

    private func hideButton(in view: NSView) -> NSButton? {
        if let button = view as? NSButton, button.action == NSSelectorFromString("hidePanel:") { return button }

        return view.subviews.lazy.compactMap { hideButton(in: $0) }.first
    }

    @Test func toolsToggleIndependentlyByZone() {
        var layout = WorkspaceLayout()
        layout.toggle(.assistant)
        layout.toggle(.terminal)
        layout.toggle(.search)
        #expect(layout.left == .search)
        #expect(layout.right == .assistant)
        #expect(layout.bottom == .terminal)
        layout.toggle(.search)
        #expect(layout.left == nil)
        #expect(layout.right == .assistant)
        layout.toggle(.build)
        #expect(layout.bottom == .build)
    }

    @Test func savedLayoutKeepsDimensionsAndHiddenPanels() throws {
        var layout = WorkspaceLayout()
        layout.left = nil
        layout.right = .inspector
        layout.bottom = .problems
        layout.leftWidth = 310
        layout.rightWidth = 280
        layout.bottomHeight = 170
        let decoded = try JSONDecoder().decode(WorkspaceLayout.self, from: JSONEncoder().encode(layout))
        #expect(decoded == layout)
    }

    @Test func realFilesProviderRendersInBothAppearances() async throws {
        _ = NSApplication.shared
        let model = ProjectFiles(root: "/preview/SwiftIDE", reader: WorkspaceDirectoryReader())
        let editor = NSTextView()
        editor.string = "Workspace\n\nThe original editor is hosted here."
        editor.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        let scroll = NSScrollView()
        scroll.documentView = editor
        let container = ProjectFilesContainer(model: model, editor: scroll, editorFocus: editor)
        container.workspace.present(detail: "Plain Text", status: "TextKit 2")
        let window = NSWindow(
            contentRect: NSRect(x: -2000, y: -2000, width: 1280, height: 820),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = container
        defer {
            container.disconnect()
            model.stop()
            window.close()
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while model.state(of: model.root) != .loaded, ContinuousClock.now < deadline { await Task.yield() }
        try #require(model.state(of: model.root) == .loaded)
        var background: [[NSColor]] = []
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            window.appearance = NSAppearance(named: appearance)
            let view = container.view
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            var samples: [NSColor] = []
            for (x, y) in [(0, 0), (bitmap.pixelsWide / 2, 0), (0, bitmap.pixelsHigh - 1)] {
                let colour = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                #expect(colour.alphaComponent > 0.99)
                samples.append(colour)
            }
            background.append(samples)
            if ProcessInfo.processInfo.environment["SWIFTIDE_RENDER_SHELL"] == "1" {
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: URL(fileURLWithPath: "/private/tmp/swiftide-workspace-\(name).png"))
            }
        }
        for (light, dark) in zip(background[0], background[1]) {
            #expect(abs(light.redComponent - dark.redComponent) < 0.005)
            #expect(abs(light.greenComponent - dark.greenComponent) < 0.005)
            #expect(abs(light.blueComponent - dark.blueComponent) < 0.005)
        }
    }

    @Test func focusAndDisabledToolsPreserveThePersistedProjectLayout() throws {
        var initial = WorkspaceLayout()
        initial.right = .assistant
        initial.bottom = .terminal
        initial.leftWidth = 350
        let state = WorkspaceLayoutState(layout: initial)
        var saved: WorkspaceLayout?
        state.onSave = { saved = $0 }
        #expect(state.layout.right == nil && state.layout.bottom == nil)
        state.select(.sourceControl)
        #expect(state.layout.left == .files && saved == nil)
        state.toggleFocus()
        #expect(state.layout.left == nil && state.isFocused)
        #expect(saved?.left == .files && saved?.leftWidth == 350)
        state.resize(left: 210)
        state.toggleFocus()
        #expect(state.layout.left == .files && state.layout.leftWidth == 350)
        state.toggleFocus()
        state.select(.files)
        #expect(!state.isFocused && state.layout.left == .files, "choosing Files while focused opens Files")
        state.select(.files)
        state.toggleFocus()
        state.toggleFocus()
        #expect(state.layout.left == nil, "a deliberately hidden panel stays hidden")
        state.reset()
        #expect(state.layout.left == .files && !state.isFocused)
        var invalid = WorkspaceLayout()
        invalid.left = .terminal
        invalid.right = .files
        invalid.leftWidth = -.infinity
        invalid.rightWidth = 100000
        invalid.bottomHeight = -1
        let validated = WorkspaceLayoutState(layout: invalid, available: Set(WorkspaceTool.allCases)).layout
        #expect(validated.left == nil && validated.right == nil)
        #expect(validated.leftWidth == 260 && validated.rightWidth == 480 && validated.bottomHeight == 140)
        #expect(try JSONDecoder().decode(WorkspaceLayout.self, from: JSONEncoder().encode(validated)) == validated)
    }

    @Test func sharedWorkspacesRetainEditorsAndNeverMoveFocusOnStatusOrLayoutNotifications() throws {
        _ = NSApplication.shared
        let state = WorkspaceLayoutState()
        let editor = NSTextView()
        editor.string = "original"
        editor.setSelectedRange(NSRange(location: 3, length: 1))
        let input = NSTextField()
        let a = WorkspaceViewController(
            state: state,
            editor: editor,
            editorFocus: editor,
            panels: [.files: .init(view: input, focusTarget: input)],
            project: "A",
            path: "/a"
        )
        let b = WorkspaceViewController(
            state: state,
            editor: NSView(),
            panels: [.files: .init(view: NSView())],
            project: "A",
            path: "/a"
        )
        let window = NSWindow(
            contentRect: NSRect(x: -2000, y: -2000, width: 1280, height: 820),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = a
        _ = b.view
        defer {
            a.disconnect()
            b.disconnect()
            window.close()
        }
        window.makeFirstResponder(editor)
        let responder = window.firstResponder
        a.present(detail: "Target: App", status: "Preparing package · 2 / 5")
        #expect(window.firstResponder === responder)
        #expect(a.buttons[.sourceControl]?.isEnabled == false)
        #expect(a.buttons[.sourceControl]?.accessibilityValue() as? String == "Unavailable")
        a.select(.sourceControl)
        #expect(state.layout.left == .files)
        state.select(.files)
        #expect(a.horizontal.splitViewItems[0].isCollapsed && b.horizontal.splitViewItems[0].isCollapsed)
        #expect(window.firstResponder === responder)
        a.toggleFocusEditor(nil)
        a.toggleFocusEditor(nil)
        #expect(a.horizontal.splitViewItems[0].isCollapsed)
        a.resetWorkspaceLayout(nil)
        #expect(!a.horizontal.splitViewItems[0].isCollapsed && !b.horizontal.splitViewItems[0].isCollapsed)
        #expect(editor.string == "original" && editor.selectedRange() == NSRange(location: 3, length: 1))
        #expect(editor.isDescendant(of: a.view))
        b.disconnect()
        state.select(.files)
        #expect(!b.horizontal.splitViewItems[0].isCollapsed, "a disconnected workspace no longer observes the project")
    }

    @Test func panelSwitchingRetainsDraftAndSmallWindowDoesNotOverwritePreferredSizes() throws {
        _ = NSApplication.shared
        let state = WorkspaceLayoutState(available: Set(WorkspaceTool.allCases))
        let draft = NSTextField(string: "saved draft")
        let workspace = WorkspaceViewController(
            state: state,
            editor: NSView(),
            panels: [
                .files: .init(view: NSView()),
                .assistant: .init(view: draft),
                .inspector: .init(view: NSView()),
                .terminal: .init(view: NSView())
            ],
            project: "Preview",
            path: "/preview"
        )
        let window = NSWindow(
            contentRect: NSRect(x: -2000, y: -2000, width: 1280, height: 820),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = workspace
        defer {
            workspace.disconnect()
            window.close()
        }
        workspace.select(.assistant)
        workspace.select(.inspector)
        workspace.select(.assistant)
        workspace.select(.terminal)
        #expect(draft.stringValue == "saved draft" && draft.isDescendant(of: workspace.view))
        state.resize(left: 310, right: 280, bottom: 180)
        let preferred = state.persistentLayout
        window.setContentSize(NSSize(width: 900, height: 560))
        workspace.view.layoutSubtreeIfNeeded()
        #expect(state.persistentLayout == preferred)
        #expect(workspace.horizontal.splitViewItems[1].viewController.view.bounds.width >= 358)
        workspace.toggleFocusEditor(nil)
        workspace.toggleFocusEditor(nil)
        #expect(state.persistentLayout == preferred)
        // AppKit has compressed the panes. A subsequent user drag in this small window must
        // persist the dragged dimension, without overwriting the other preferred dimensions.
        // At the 900 pt minimum the panes sit at their minimum widths, so a drag has no room to move.
        window.setContentSize(NSSize(width: 920, height: 560))
        workspace.view.layoutSubtreeIfNeeded()
        let split = try #require(workspace.horizontal.splitView as? WorkspaceSplitView)
        let before = split.subviews.map { $0.frame.width }
        split.setPosition(205, ofDividerAt: 0)
        workspace.view.layoutSubtreeIfNeeded()
        let dragged = split.subviews[0].frame.width
        split.onDividerDrag?(before)
        #expect(abs(state.layout.leftWidth - dragged) < 2)
        #expect(state.layout.bottomHeight == preferred.bottomHeight)
    }
}

private struct WorkspaceDirectoryReader: ProjectDirectoryReading {
    func children(of path: String) async throws -> [ProjectFile] {
        [
            ProjectFile(path: path + "/Sources", isDirectory: true),
            ProjectFile(path: path + "/.build", isDirectory: true),
            ProjectFile(path: path + "/Package.swift", isDirectory: false),
            ProjectFile(path: path + "/README.md", isDirectory: false)
        ]
    }
}
