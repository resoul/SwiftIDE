import AppKit
import WorkspaceUI

/// Sample providers for the same shell that real project windows use.
@MainActor
final class WorkspacePreviewWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    let shell: WorkspaceShellViewController
    private let preferences: UserDefaults
    private let preferenceKey = "workspacePreview.layout.v1"

    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        let layout = preferences.data(forKey: preferenceKey)
            .flatMap { try? JSONDecoder().decode(WorkspaceLayout.self, from: $0) } ?? .init()
        let state = WorkspaceLayoutState(layout: layout, available: Set(WorkspaceTool.allCases))
        let samples = PreviewPanels()
        var panels: [WorkspaceTool: WorkspacePanel] = [:]
        for tool in WorkspaceTool.allCases {
            let view = samples.makeBody(tool)
            panels[tool] = WorkspacePanel(view: view, focusTarget: samples.focusTargets[tool])
        }
        let editor = NSTextView()
        editor.string = "Workspace Preview\n\nThis window uses sample content.\nOpen Folder… opens the same shell with real Files and editor tabs."
        editor.isEditable = false
        editor.isRichText = false
        editor.font = .systemFont(ofSize: 16)
        editor.textColor = .secondaryLabelColor
        editor.drawsBackground = false
        editor.textContainerInset = NSSize(width: 48, height: 72)
        editor.autoresizingMask = [.width]
        editor.isVerticallyResizable = true
        editor.textContainer?.widthTracksTextView = true
        let scroll = NSScrollView()
        scroll.documentView = editor
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        shell = WorkspaceShellViewController(state: state, editor: scroll, editorFocus: editor, panels: panels, project: "SwiftIDE · Preview", path: "Sample workspace")
        shell.present(detail: "⑂ main · sample", status: "Sample data · no tools connected")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "SwiftIDE — Workspace Preview"
        window.subtitle = "Layout prototype"
        window.minSize = NSSize(width: 900, height: 560)
        window.isReleasedWhenClosed = false
        window.contentViewController = shell
        super.init(window: window)
        window.delegate = self
        state.onSave = { [weak self] in self?.persist($0) }
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        shell.focusEditor()
    }

    private func persist(_ layout: WorkspaceLayout) {
        preferences.set(try? JSONEncoder().encode(layout), forKey: preferenceKey)
    }
    @objc func showPreviewFiles(_ sender: Any?) { shell.select(.files) }
    @objc func showPreviewSearch(_ sender: Any?) { shell.select(.search) }
    @objc func showPreviewSourceControl(_ sender: Any?) { shell.select(.sourceControl) }
    @objc func showPreviewTerminal(_ sender: Any?) { shell.select(.terminal) }
    @objc func showPreviewAssistant(_ sender: Any?) { shell.select(.assistant) }
    @objc func toggleFocusEditor(_ sender: Any?) { shell.toggleFocusEditor(sender) }
    @objc func resetWorkspaceLayout(_ sender: Any?) { shell.resetWorkspaceLayout(sender) }
    @objc func previewLightAppearance(_ sender: Any?) { window?.appearance = NSAppearance(named: .aqua) }
    @objc func previewDarkAppearance(_ sender: Any?) { window?.appearance = NSAppearance(named: .darkAqua) }
    @objc func previewSystemAppearance(_ sender: Any?) { window?.appearance = nil }
    func windowWillClose(_ notification: Notification) { persist(shell.state.persistentLayout) }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { true }
}

@MainActor
private final class PreviewPanels {
    var focusTargets: [WorkspaceTool: NSView] = [:]
    func makeBody(_ tool: WorkspaceTool) -> NSView {
        switch tool {
        case .files:
            let list = NSTextView()
            list.string = "▾ SwiftIDE  ·  sample\n\n   ▾ Apps\n       ▾ SwiftIDE\n           AppDelegate.swift\n           MainMenu.swift\n\n   ▸ Packages\n   ▸ docs\n   ▸ Tools\n\n     Package.swift\n     README.md"
            list.isEditable = false
            list.font = .systemFont(ofSize: 13)
            list.textColor = .labelColor
            list.drawsBackground = false
            list.textContainerInset = NSSize(width: 14, height: 16)
            focusTargets[tool] = list

            return scroll(list)
        case .search, .assistant:
            let field = NSTextField()
            field.placeholderString = tool == .search ? "Search sample workspace…" : "Draft a message…"
            field.setAccessibilityLabel(tool == .search ? "Search query" : "Assistant draft")
            focusTargets[tool] = field
            let note = label(tool == .search ? "Search is not connected yet." : "Assistant is not connected yet.\nYour draft stays here while the panel is hidden.", secondary: true)
            note.maximumNumberOfLines = 0
            let body = stack([note, field, NSView()], vertical: true, spacing: 14, insets: NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16))

            return body
        default:
            let text = NSTextView()
            text.isEditable = tool == .terminal
            text.isRichText = false
            text.font = tool == .terminal ? .monospacedSystemFont(ofSize: 13, weight: .regular) : .systemFont(ofSize: 13)
            text.textColor = .secondaryLabelColor
            text.drawsBackground = false
            text.textContainerInset = NSSize(width: 16, height: 16)
            switch tool {
            case .terminal: text.string = "Terminal preview — no commands are executed.\n\nYou can type here to test focus and panel resizing.\n"
            case .build: text.string = "Build output will appear here.\nNo build service is connected."
            case .problems: text.string = "Diagnostics will appear here.\nNo language service is connected."
            case .sourceControl: text.string = "Source Control preview\n\nChanges\n   M  MainMenu.swift\n   A  WorkspacePreviewWindowController.swift\n\nSample data only."
            case .structure: text.string = "File structure will appear here.\nNo document is connected."
            case .inspector: text.string = "Document and project details will appear here."
            default: break
            }
            focusTargets[tool] = text

            return scroll(text)
        }
    }

    private func scroll(_ text: NSTextView) -> NSScrollView {
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        let view = NSScrollView()
        view.documentView = text
        view.hasVerticalScroller = true
        view.drawsBackground = false

        return view
    }
}

@MainActor
private func label(_ text: String, secondary: Bool) -> NSTextField {
    let field = NSTextField(labelWithString: text)
    field.textColor = secondary ? .secondaryLabelColor : .labelColor

    return field
}

@MainActor
private func stack(_ views: [NSView], vertical: Bool, spacing: CGFloat, insets: NSEdgeInsets) -> NSStackView {
    let stack = NSStackView(views: views)
    stack.orientation = vertical ? .vertical : .horizontal
    stack.spacing = spacing
    stack.edgeInsets = insets

    return stack
}
