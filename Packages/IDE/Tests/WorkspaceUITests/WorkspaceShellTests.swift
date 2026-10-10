import AppKit
import IDEApplication
import Testing
@testable import WorkspaceUI

@Suite(.serialized)
@MainActor
struct WorkspaceShellTests {
    @Test func realFilesProviderRendersInBothAppearances() async throws {
        _ = NSApplication.shared
        let model = ProjectFiles(root: "/preview/SwiftIDE", reader: ShellDirectoryReader())
        let editor = NSTextView()
        editor.string = "Workspace shell\n\nThe original editor is hosted here."
        editor.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        let scroll = NSScrollView()
        scroll.documentView = editor
        let container = ProjectFilesContainer(model: model, editor: scroll, editorFocus: editor)
        container.shell.present(detail: "Plain Text", status: "TextKit 2")
        let window = NSWindow(contentRect: NSRect(x: -2000, y: -2000, width: 1280, height: 820), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = container
        defer { container.disconnect(); model.stop(); window.close() }
        let deadline = ContinuousClock.now + .seconds(5)
        while model.state(of: model.root) != .loaded, ContinuousClock.now < deadline { await Task.yield() }
        try #require(model.state(of: model.root) == .loaded)
        var background: [CGFloat] = []
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            window.appearance = NSAppearance(named: appearance)
            let view = container.view
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let colour = try #require(bitmap.colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB))
            #expect(colour.alphaComponent > 0.9)
            background.append(colour.redComponent)
            if ProcessInfo.processInfo.environment["SWIFTIDE_RENDER_SHELL"] == "1" {
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: URL(fileURLWithPath: "/private/tmp/swiftide-shell-\(name).png"))
            }
        }
        #expect(background[0] > background[1] + 0.4, "the shared shell resolves the window's appearance")
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

    @Test func sharedShellsRetainEditorsAndNeverMoveFocusOnStatusOrLayoutNotifications() throws {
        _ = NSApplication.shared
        let state = WorkspaceLayoutState()
        let editor = NSTextView()
        editor.string = "original"
        editor.setSelectedRange(NSRange(location: 3, length: 1))
        let input = NSTextField()
        let a = WorkspaceShellViewController(state: state, editor: editor, editorFocus: editor, panels: [.files: .init(view: input, focusTarget: input)], project: "A", path: "/a")
        let b = WorkspaceShellViewController(state: state, editor: NSView(), panels: [.files: .init(view: NSView())], project: "A", path: "/a")
        let window = NSWindow(contentRect: NSRect(x: -2000, y: -2000, width: 1280, height: 820), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = a
        _ = b.view
        defer { a.disconnect(); b.disconnect(); window.close() }
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
        #expect(!b.horizontal.splitViewItems[0].isCollapsed, "a disconnected shell no longer observes the project")
    }

    @Test func panelSwitchingRetainsDraftAndSmallWindowDoesNotOverwritePreferredSizes() throws {
        _ = NSApplication.shared
        let state = WorkspaceLayoutState(available: Set(WorkspaceTool.allCases))
        let draft = NSTextField(string: "saved draft")
        let shell = WorkspaceShellViewController(state: state, editor: NSView(), panels: [.files: .init(view: NSView()), .assistant: .init(view: draft), .inspector: .init(view: NSView()), .terminal: .init(view: NSView())], project: "Preview", path: "/preview")
        let window = NSWindow(contentRect: NSRect(x: -2000, y: -2000, width: 1280, height: 820), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = shell
        defer { shell.disconnect(); window.close() }
        shell.select(.assistant)
        shell.select(.inspector)
        shell.select(.assistant)
        shell.select(.terminal)
        #expect(draft.stringValue == "saved draft" && draft.isDescendant(of: shell.view))
        state.resize(left: 310, right: 280, bottom: 180)
        let preferred = state.persistentLayout
        window.setContentSize(NSSize(width: 900, height: 560))
        shell.view.layoutSubtreeIfNeeded()
        #expect(state.persistentLayout == preferred)
        #expect(shell.horizontal.splitViewItems[1].viewController.view.bounds.width >= 358)
        shell.toggleFocusEditor(nil)
        shell.toggleFocusEditor(nil)
        #expect(state.persistentLayout == preferred)
        // AppKit has compressed the panes. A subsequent user drag in this small window must
        // persist the dragged dimension, without overwriting the other preferred dimensions.
        let split = try #require(shell.horizontal.splitView as? WorkspaceSplitView)
        let before = split.subviews.map { $0.frame.width }
        split.setPosition(205, ofDividerAt: 0)
        shell.view.layoutSubtreeIfNeeded()
        let dragged = split.subviews[0].frame.width
        split.onDividerDrag?(before)
        #expect(abs(state.layout.leftWidth - dragged) < 2)
        #expect(state.layout.bottomHeight == preferred.bottomHeight)
    }
}

private struct ShellDirectoryReader: ProjectDirectoryReading {
    func children(of path: String) async throws -> [ProjectFile] {
        [ProjectFile(path: path + "/Sources", isDirectory: true),
         ProjectFile(path: path + "/.build", isDirectory: true),
         ProjectFile(path: path + "/Package.swift", isDirectory: false),
         ProjectFile(path: path + "/README.md", isDirectory: false)]
    }
}
