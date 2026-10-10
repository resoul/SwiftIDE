import AppKit

/// UI-only workspace prototype. It owns no document and executes no shell commands.
@MainActor
final class WorkspacePreviewWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    private let horizontal = NSSplitViewController()
    private let vertical = NSSplitViewController()
    private let left = PreviewPanel()
    private let right = PreviewPanel()
    private let bottom = PreviewPanel()
    private let editor = NSTextView()
    private var leftItem: NSSplitViewItem!
    private var rightItem: NSSplitViewItem!
    private var bottomItem: NSSplitViewItem!
    private var buttons: [WorkspaceTool: NSButton] = [:]
    private var layout: WorkspacePreviewLayout
    private var focusLayout: WorkspacePreviewLayout?
    private var isUpdatingLayout = false
    private let preferences: UserDefaults
    private let preferenceKey = "workspacePreview.layout.v1"

    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        layout = preferences.data(forKey: preferenceKey)
            .flatMap { try? JSONDecoder().decode(WorkspacePreviewLayout.self, from: $0) } ?? .init()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "SwiftIDE — Workspace Preview"
        window.subtitle = "Layout prototype"
        window.minSize = NSSize(width: 900, height: 560)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildContent(window)
        render()
        for split in [horizontal.splitView, vertical.splitView] {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(dividersDidResize(_:)),
                name: NSSplitView.didResizeSubviewsNotification,
                object: split
            )
        }
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeFirstResponder(editor)
    }

    private func buildContent(_ window: NSWindow) {
        editor.string = "Workspace Preview\n\nYour editor will live here.\n\nUse the tool rails to show Files, Search, Source Control,\nTerminal, Build, Problems or Assistant.\n\nDrag the dividers to resize panels.\nView → Focus Editor hides panels and restores your layout.\n\nThis window uses sample content. Open… still opens the real editor."
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
        let center = NSViewController()
        center.view = surface(stack([header("Editor", detail: "No document connected"), scroll], vertical: true), role: .editor)

        horizontal.splitView.isVertical = true
        horizontal.splitView.dividerStyle = .thin
        leftItem = NSSplitViewItem(viewController: controller(surface(left)))
        leftItem.canCollapse = true
        leftItem.minimumThickness = 200
        leftItem.maximumThickness = 440
        let centerItem = NSSplitViewItem(viewController: center)
        centerItem.minimumThickness = 360
        rightItem = NSSplitViewItem(viewController: controller(surface(right)))
        rightItem.canCollapse = true
        rightItem.minimumThickness = 240
        rightItem.maximumThickness = 480
        horizontal.addSplitViewItem(leftItem)
        horizontal.addSplitViewItem(centerItem)
        horizontal.addSplitViewItem(rightItem)

        vertical.splitView.isVertical = false
        vertical.splitView.dividerStyle = .thin
        let top = NSSplitViewItem(viewController: horizontal)
        top.minimumThickness = 260
        bottomItem = NSSplitViewItem(viewController: controller(surface(bottom)))
        bottomItem.canCollapse = true
        bottomItem.minimumThickness = 140
        bottomItem.maximumThickness = 380
        vertical.addSplitViewItem(top)
        vertical.addSplitViewItem(bottomItem)

        let body = stack([rail(leftSide: true), vertical.view, rail(leftSide: false)], vertical: false)
        let root = stack([toolbar(), body, statusBar()], vertical: true)
        let background = WorkspaceBackgroundView(role: .chrome)
        pin(root, to: background)
        window.contentView = background
        background.layoutSubtreeIfNeeded()
        // Set initial dimensions before hiding panes; AppKit retains them while collapsed.
        horizontal.splitView.setPosition(layout.leftWidth, ofDividerAt: 0)
        horizontal.splitView.setPosition(horizontal.view.bounds.width - layout.rightWidth, ofDividerAt: 1)
        vertical.splitView.setPosition(vertical.view.bounds.height - layout.bottomHeight, ofDividerAt: 0)
    }

    private func toolbar() -> NSView {
        let project = label("SwiftIDE", weight: .semibold)
        let branch = label("⑂ main · sample", secondary: true)
        let scheme = label("Scheme: not connected", secondary: true)
        let destination = label("Destination: not connected", secondary: true)
        let focus = NSButton(title: "Focus Editor", target: self, action: #selector(toggleFocusEditor(_:)))
        let reset = NSButton(title: "Reset Layout", target: self, action: #selector(resetWorkspaceLayout(_:)))
        let row = stack([project, branch, NSView(), scheme, destination, focus, reset], vertical: false, spacing: 16)

        return padded(row, height: 46)
    }

    private func statusBar() -> NSView {
        padded(stack([
            label("WORKSPACE PREVIEW", secondary: true),
            NSView(),
            label("Sample data · no terminal or AI connection", secondary: true)
        ], vertical: false), height: 28)
    }

    private func rail(leftSide: Bool) -> NSView {
        var views: [NSView] = []
        let tools: [WorkspaceTool] = leftSide ? [.files, .search, .sourceControl] : [.assistant, .structure, .inspector]
        for tool in tools { views.append(toolButton(tool)) }
        views.append(NSView())
        if leftSide {
            for tool in [WorkspaceTool.terminal, .build, .problems] { views.append(toolButton(tool)) }
        }

        let rail = stack(views, vertical: true, spacing: 8, insets: NSEdgeInsets(top: 10, left: 6, bottom: 10, right: 6))
        rail.widthAnchor.constraint(equalToConstant: 44).isActive = true

        return rail
    }

    private func toolButton(_ tool: WorkspaceTool) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: tool.symbol, accessibilityDescription: tool.title)!, target: self, action: #selector(selectTool(_:)))
        button.tag = tool.rawValue
        button.isBordered = false
        button.toolTip = tool.title
        button.setAccessibilityLabel(tool.title)
        button.widthAnchor.constraint(equalToConstant: 32).isActive = true
        button.heightAnchor.constraint(equalToConstant: 32).isActive = true
        buttons[tool] = button

        return button
    }

    @objc private func selectTool(_ sender: NSButton) {
        guard let tool = WorkspaceTool(rawValue: sender.tag) else { return }

        select(tool)
    }

    private func select(_ tool: WorkspaceTool) {
        rememberSizes()
        if let previous = focusLayout { layout = previous; focusLayout = nil }
        layout.toggle(tool)
        render()
        persist()
        focus(tool)
    }

    @objc func showPreviewFiles(_ sender: Any?) { select(.files) }
    @objc func showPreviewSearch(_ sender: Any?) { select(.search) }
    @objc func showPreviewSourceControl(_ sender: Any?) { select(.sourceControl) }
    @objc func showPreviewTerminal(_ sender: Any?) { select(.terminal) }
    @objc func showPreviewAssistant(_ sender: Any?) { select(.assistant) }

    @objc func previewLightAppearance(_ sender: Any?) { window?.appearance = NSAppearance(named: .aqua) }
    @objc func previewDarkAppearance(_ sender: Any?) { window?.appearance = NSAppearance(named: .darkAqua) }
    @objc func previewSystemAppearance(_ sender: Any?) { window?.appearance = nil }

    @objc private func dividersDidResize(_ notification: Notification) {
        guard !isUpdatingLayout, focusLayout == nil else { return }

        rememberSizes()
        persist()
    }

    @objc func toggleFocusEditor(_ sender: Any?) {
        if let previous = focusLayout {
            layout = previous
            focusLayout = nil
        } else {
            rememberSizes()
            focusLayout = layout
            layout.left = nil
            layout.right = nil
            layout.bottom = nil
        }

        render()
        window?.makeFirstResponder(editor)
    }

    @objc func resetWorkspaceLayout(_ sender: Any?) {
        focusLayout = nil
        layout = .init()
        render()
        horizontal.splitView.setPosition(layout.leftWidth, ofDividerAt: 0)
        window?.makeFirstResponder(editor)
        persist()
    }

    private func render() {
        isUpdatingLayout = true
        defer { isUpdatingLayout = false }
        leftItem.isCollapsed = layout.left == nil
        rightItem.isCollapsed = layout.right == nil
        bottomItem.isCollapsed = layout.bottom == nil
        window?.contentView?.layoutSubtreeIfNeeded()
        if layout.left != nil {
            horizontal.splitView.setPosition(layout.leftWidth, ofDividerAt: 0)
        }

        if layout.right != nil {
            horizontal.splitView.setPosition(horizontal.view.bounds.width - layout.rightWidth, ofDividerAt: 1)
        }

        if layout.bottom != nil {
            vertical.splitView.setPosition(vertical.view.bounds.height - layout.bottomHeight, ofDividerAt: 0)
        }

        if let tool = layout.left { configure(left, for: tool) }
        if let tool = layout.right { configure(right, for: tool) }
        if let tool = layout.bottom { configure(bottom, for: tool) }
        for (tool, button) in buttons {
            let selected = layout.contains(tool)
            button.contentTintColor = selected ? .controlAccentColor : .secondaryLabelColor
            button.state = selected ? .on : .off
            button.setAccessibilityValue(selected ? "Selected" : "Hidden")
        }
    }

    private func focus(_ tool: WorkspaceTool) {
        guard layout.contains(tool) else { window?.makeFirstResponder(editor); return }

        let panel = tool.zone == .left ? left : tool.zone == .right ? right : bottom
        window?.makeFirstResponder(panel.focusTarget)
    }

    private func configure(_ panel: PreviewPanel, for tool: WorkspaceTool) {
        // Keep inputs and selection when switching away and returning to a tool.
        panel.show(tool: tool, target: self, hide: #selector(hidePanel(_:)))
    }

    @objc private func hidePanel(_ sender: NSButton) {
        guard let tool = WorkspaceTool(rawValue: sender.tag) else { return }

        select(tool)
    }

    private func rememberSizes() {
        if !leftItem.isCollapsed { layout.leftWidth = leftItem.viewController.view.bounds.width }
        if !rightItem.isCollapsed { layout.rightWidth = rightItem.viewController.view.bounds.width }
        if !bottomItem.isCollapsed { layout.bottomHeight = bottomItem.viewController.view.bounds.height }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(focusLayout ?? layout) { preferences.set(data, forKey: preferenceKey) }
    }

    func windowWillClose(_ notification: Notification) {
        if focusLayout == nil { rememberSizes() }
        persist()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { true }
}

enum WorkspaceTool: Int, Codable, CaseIterable {
    case files, search, sourceControl, terminal, build, problems, assistant, structure, inspector
    enum Zone { case left, right, bottom }
    var zone: Zone {
        switch self {
        case .files, .search, .sourceControl: .left
        case .assistant, .structure, .inspector: .right
        case .terminal, .build, .problems: .bottom
        }
    }
    var title: String {
        switch self {
        case .files: "Files"
        case .search: "Search"
        case .sourceControl: "Source Control"
        case .terminal: "Terminal"
        case .build: "Build Output"
        case .problems: "Problems"
        case .assistant: "Assistant"
        case .structure: "Structure"
        case .inspector: "Inspector"
        }
    }
    var symbol: String {
        switch self {
        case .files: "folder"
        case .search: "magnifyingglass"
        case .sourceControl: "arrow.triangle.branch"
        case .terminal: "terminal"
        case .build: "hammer"
        case .problems: "exclamationmark.circle"
        case .assistant: "bubble.left.and.bubble.right"
        case .structure: "list.bullet.indent"
        case .inspector: "slider.horizontal.3"
        }
    }
}

struct WorkspacePreviewLayout: Codable, Equatable {
    var left: WorkspaceTool? = .files
    var right: WorkspaceTool?
    var bottom: WorkspaceTool?
    var leftWidth: Double = 260
    var rightWidth: Double = 300
    var bottomHeight: Double = 220

    mutating func toggle(_ tool: WorkspaceTool) {
        switch tool.zone {
        case .left: left = left == tool ? nil : tool
        case .right: right = right == tool ? nil : tool
        case .bottom: bottom = bottom == tool ? nil : tool
        }
    }
    func contains(_ tool: WorkspaceTool) -> Bool {
        left == tool || right == tool || bottom == tool
    }
}

@MainActor
private final class PreviewPanel: NSView {
    private var content: [WorkspaceTool: NSView] = [:]
    private var focusTargets: [WorkspaceTool: NSView] = [:]
    private var current: NSView?
    private(set) var focusTarget: NSView?

    func show(tool: WorkspaceTool, target: AnyObject, hide action: Selector) {
        guard current?.identifier?.rawValue != tool.title else { return }

        current?.removeFromSuperview()
        let body: NSView
        if let cached = content[tool] { body = cached } else {
            body = makeBody(tool)
            content[tool] = body
        }

        let close = NSButton(image: NSImage(systemSymbolName: "minus", accessibilityDescription: "Hide \(tool.title)")!, target: target, action: action)
        close.isBordered = false
        close.tag = tool.rawValue
        let heading = padded(stack([label(tool.title, weight: .semibold), NSView(), close], vertical: false), height: 38)
        let container = stack([heading, body], vertical: true)
        container.identifier = NSUserInterfaceItemIdentifier(tool.title)
        pin(container, to: self)
        current = container
        focusTarget = focusTargets[tool]
    }

    private func makeBody(_ tool: WorkspaceTool) -> NSView {
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
private func controller(_ view: NSView) -> NSViewController {
    let result = NSViewController()
    result.view = view

    return result
}

@MainActor
private func label(_ text: String, weight: NSFont.Weight = .regular, secondary: Bool = false) -> NSTextField {
    let field = NSTextField(labelWithString: text)
    field.font = .systemFont(ofSize: 12, weight: weight)
    field.textColor = secondary ? .secondaryLabelColor : .labelColor

    return field
}

@MainActor
private func stack(_ views: [NSView], vertical: Bool, spacing: CGFloat = 0, insets: NSEdgeInsets = NSEdgeInsets()) -> NSStackView {
    let view = NSStackView(views: views)
    view.orientation = vertical ? .vertical : .horizontal
    view.alignment = vertical ? .leading : .top
    view.edgeInsets = insets
    view.distribution = .fill
    view.spacing = spacing
    views.forEach {
        $0.translatesAutoresizingMaskIntoConstraints = false
        if vertical {
            $0.widthAnchor.constraint(equalTo: view.widthAnchor, constant: -insets.left - insets.right).isActive = true
        } else {
            $0.heightAnchor.constraint(equalTo: view.heightAnchor, constant: -insets.top - insets.bottom).isActive = true
        }
    }

    return view
}

@MainActor
private func padded(_ content: NSView, height: CGFloat) -> NSView {
    let view = NSView()
    view.heightAnchor.constraint(equalToConstant: height).isActive = true
    view.addSubview(content)
    content.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
        content.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
        content.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
        content.centerYAnchor.constraint(equalTo: view.centerYAnchor)
    ])

    return view
}

@MainActor
private func header(_ title: String, detail: String) -> NSView {
    padded(stack([label(title, weight: .semibold), NSView(), label(detail, secondary: true)], vertical: false), height: 38)
}

@MainActor
private func pin(_ view: NSView, to parent: NSView) {
    parent.addSubview(view)
    view.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
        view.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
        view.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
        view.topAnchor.constraint(equalTo: parent.topAnchor),
        view.bottomAnchor.constraint(equalTo: parent.bottomAnchor)
    ])
}

/// Colours resolve for the window appearance, including theme changes while open.
@MainActor
private final class WorkspaceBackgroundView: NSView {
    enum Role { case chrome, panel, editor }
    private let role: Role

    init(role: Role) {
        self.role = role
        super.init(frame: .zero)
        wantsLayer = true
        if role != .chrome {
            layer?.cornerRadius = 10
            layer?.masksToBounds = true
            layer?.borderWidth = 0.5
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let white: CGFloat
            switch role {
            case .chrome: white = dark ? 0.155 : 0.90
            case .panel: white = dark ? 0.115 : 0.965
            case .editor: white = dark ? 0.095 : 1.0
            }
            layer?.backgroundColor = NSColor(white: white, alpha: 1).cgColor
            layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.45).cgColor
        }
    }
}

@MainActor
private func surface(_ content: NSView, role: WorkspaceBackgroundView.Role = .panel) -> NSView {
    let outer = NSView()
    let card = WorkspaceBackgroundView(role: role)
    pin(content, to: card)
    outer.addSubview(card)
    card.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
        card.leadingAnchor.constraint(equalTo: outer.leadingAnchor, constant: 4),
        card.trailingAnchor.constraint(equalTo: outer.trailingAnchor, constant: -4),
        card.topAnchor.constraint(equalTo: outer.topAnchor, constant: 4),
        card.bottomAnchor.constraint(equalTo: outer.bottomAnchor, constant: -4)
    ])

    return outer
}
