import AppKit

/// A caller-provided tool view. The shell retains its view and focus target across panel switches.
@MainActor
public struct WorkspacePanel {
    public let view: NSView
    public let focusTarget: NSView?
    public init(view: NSView, focusTarget: NSView? = nil) {
        self.view = view
        self.focusTarget = focusTarget
    }
}

/// Geometry, tool rails and presentation only. It owns no document and runs no tools.
@MainActor
public final class WorkspaceShellViewController: NSViewController {
    public let state: WorkspaceLayoutState
    let horizontal = NSSplitViewController()
    let vertical = NSSplitViewController()
    private let left = ShellPanel()
    private let right = ShellPanel()
    private let bottom = ShellPanel()
    private let editor: NSView
    private let editorFocus: NSView?
    private let panels: [WorkspaceTool: WorkspacePanel]
    private var leftItem: NSSplitViewItem!
    private var rightItem: NSSplitViewItem!
    private var bottomItem: NSSplitViewItem!
    private(set) var buttons: [WorkspaceTool: NSButton] = [:]
    private let projectLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let pathLabel = NSTextField(labelWithString: "")
    private var subscription: UUID?
    private var isUpdatingLayout = false
    private var lastSize: NSSize = .zero

    public init(
        state: WorkspaceLayoutState,
        editor: NSView,
        editorFocus: NSView? = nil,
        panels: [WorkspaceTool: WorkspacePanel],
        project: String,
        path: String
    ) {
        self.state = state
        self.editor = editor
        self.editorFocus = editorFocus
        self.panels = panels
        super.init(nibName: nil, bundle: nil)
        projectLabel.stringValue = project
        projectLabel.toolTip = path
        pathLabel.stringValue = path
        pathLabel.toolTip = path
        subscription = state.subscribe { [weak self] in self?.render() }
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func loadView() {
        view = WorkspaceBackgroundView(role: .chrome)
        view.frame = NSRect(x: 0, y: 0, width: 1280, height: 820)
        let horizontalSplit = WorkspaceSplitView()
        horizontalSplit.onDividerDrag = { [weak self] before in self?.rememberDraggedSizes(before: before, vertical: false) }
        horizontal.splitView = horizontalSplit
        let verticalSplit = WorkspaceSplitView()
        verticalSplit.onDividerDrag = { [weak self] before in self?.rememberDraggedSizes(before: before, vertical: true) }
        vertical.splitView = verticalSplit
        horizontal.splitView.isVertical = true
        horizontal.splitView.dividerStyle = .thin
        leftItem = NSSplitViewItem(viewController: controller(surface(left)))
        leftItem.canCollapse = true
        leftItem.minimumThickness = 200
        leftItem.maximumThickness = 440
        let centre = NSSplitViewItem(viewController: controller(surface(editor, role: .editor)))
        centre.minimumThickness = 360
        rightItem = NSSplitViewItem(viewController: controller(surface(right)))
        rightItem.canCollapse = true
        rightItem.minimumThickness = 240
        rightItem.maximumThickness = 480
        horizontal.addSplitViewItem(leftItem)
        horizontal.addSplitViewItem(centre)
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
        pin(stack([toolbar(), body, statusBar()], vertical: true), to: view)
        render()
    }

    public override func viewDidLayout() {
        super.viewDidLayout()
        guard !isUpdatingLayout, lastSize != view.bounds.size else { return }

        lastSize = view.bounds.size
        render()
    }

    public override func viewWillAppear() {
        super.viewWillAppear()
        render()
    }

    /// Updates never alter focus, panel selection or an editor's text.
    public func present(detail: String?, status: String?) {
        detailLabel.stringValue = detail ?? ""
        detailLabel.toolTip = detail
        statusLabel.stringValue = status ?? ""
        statusLabel.toolTip = status
    }

    public func disconnect() {
        if let subscription { state.unsubscribe(subscription) }
        subscription = nil
        (horizontal.splitView as? WorkspaceSplitView)?.onDividerDrag = nil
        (vertical.splitView as? WorkspaceSplitView)?.onDividerDrag = nil
    }

    public func select(_ tool: WorkspaceTool) {
        guard state.available.contains(tool), panels[tool] != nil else { return }

        state.select(tool)
        if state.layout.contains(tool), let target = panels[tool]?.focusTarget {
            view.window?.makeFirstResponder(target)
        } else {
            focusEditor()
        }
    }

    @objc public func toggleFocusEditor(_ sender: Any?) {
        state.toggleFocus()
        focusEditor()
    }

    @objc public func resetWorkspaceLayout(_ sender: Any?) {
        state.reset()
        focusEditor()
    }

    public func focusEditor() {
        if let editorFocus { view.window?.makeFirstResponder(editorFocus) }
    }

    private func toolbar() -> NSView {
        projectLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.textColor = .secondaryLabelColor
        projectLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.lineBreakMode = .byTruncatingTail
        projectLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let focus = NSButton(title: "Focus Editor", target: self, action: #selector(toggleFocusEditor(_:)))
        let reset = NSButton(title: "Reset Layout", target: self, action: #selector(resetWorkspaceLayout(_:)))

        return padded(stack([projectLabel, NSView(), detailLabel, focus, reset], vertical: false, spacing: 12), height: 46)
    }

    private func statusBar() -> NSView {
        for field in [pathLabel, statusLabel] {
            field.font = .systemFont(ofSize: 11)
            field.textColor = .secondaryLabelColor
            field.lineBreakMode = .byTruncatingMiddle
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }

        return padded(stack([pathLabel, NSView(), statusLabel], vertical: false, spacing: 12), height: 28)
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
        let button = NSButton(title: "", target: self, action: #selector(selectTool(_:)))
        button.image = NSImage(systemSymbolName: tool.symbol, accessibilityDescription: tool.title)
        button.tag = tool.rawValue
        button.isBordered = false
        button.isEnabled = state.available.contains(tool) && panels[tool] != nil
        button.toolTip = button.isEnabled ? tool.title : tool.title + " — not available yet"
        button.setAccessibilityLabel(button.toolTip)
        button.widthAnchor.constraint(equalToConstant: 32).isActive = true
        button.heightAnchor.constraint(equalToConstant: 32).isActive = true
        buttons[tool] = button

        return button
    }

    @objc private func selectTool(_ sender: NSButton) {
        guard let tool = WorkspaceTool(rawValue: sender.tag) else { return }

        select(tool)
    }

    private func render() {
        guard isViewLoaded, !isUpdatingLayout else { return }

        isUpdatingLayout = true
        defer { isUpdatingLayout = false }
        let layout = state.layout
        leftItem.isCollapsed = layout.left == nil
        rightItem.isCollapsed = layout.right == nil
        bottomItem.isCollapsed = layout.bottom == nil
        if let tool = layout.left, let panel = panels[tool] { left.show(panel, tool: tool, target: self) }
        if let tool = layout.right, let panel = panels[tool] { right.show(panel, tool: tool, target: self) }
        if let tool = layout.bottom, let panel = panels[tool] { bottom.show(panel, tool: tool, target: self) }
        view.layoutSubtreeIfNeeded()
        if layout.left != nil { horizontal.splitView.setPosition(layout.leftWidth, ofDividerAt: 0) }
        if layout.right != nil { horizontal.splitView.setPosition(horizontal.view.bounds.width - layout.rightWidth, ofDividerAt: 1) }
        if layout.bottom != nil { vertical.splitView.setPosition(vertical.view.bounds.height - layout.bottomHeight, ofDividerAt: 0) }
        for (tool, button) in buttons {
            let selected = layout.contains(tool)
            button.contentTintColor = selected ? .controlAccentColor : .secondaryLabelColor
            button.state = selected ? .on : .off
            button.setAccessibilityValue(button.isEnabled ? (selected ? "Selected" : "Hidden") : "Unavailable")
        }
    }

    private func rememberDraggedSizes(before: [CGFloat], vertical: Bool) {
        guard !isUpdatingLayout, !state.isFocused else { return }

        let split = vertical ? self.vertical.splitView : horizontal.splitView
        let after = split.subviews.map { vertical ? $0.frame.height : $0.frame.width }
        guard before.count == after.count, after.count >= 2 else { return }

        // Only user divider drags change the preferred dimensions. Window resizing and rendering
        // can compress panes, but do not replace the project's saved preferences.
        state.resize(
            left: !vertical && !leftItem.isCollapsed && abs(after[0] - before[0]) > 1 ? after[0] : nil,
            right: !vertical && !rightItem.isCollapsed && abs(after[after.count - 1] - before[before.count - 1]) > 1 ? after[after.count - 1] : nil,
            bottom: vertical && !bottomItem.isCollapsed && abs(after[1] - before[1]) > 1 ? after[1] : nil
        )
    }

    @objc fileprivate func hidePanel(_ sender: NSButton) {
        guard let tool = WorkspaceTool(rawValue: sender.tag) else { return }

        select(tool)
    }
}

@MainActor
final class WorkspaceSplitView: NSSplitView {
    var onDividerDrag: (([CGFloat]) -> Void)?
    override func mouseDown(with event: NSEvent) {
        let before = subviews.map { isVertical ? $0.frame.width : $0.frame.height }
        super.mouseDown(with: event)
        onDividerDrag?(before)
    }
}

@MainActor
private final class ShellPanel: NSView {
    private var current: NSView?
    private var tool: WorkspaceTool?
    func show(_ panel: WorkspacePanel, tool: WorkspaceTool, target: WorkspaceShellViewController) {
        guard self.tool != tool else { return }

        current?.removeFromSuperview()
        let close = NSButton(title: "", target: target, action: #selector(WorkspaceShellViewController.hidePanel(_:)))
        close.image = NSImage(systemSymbolName: "minus", accessibilityDescription: "Hide " + tool.title)
        close.isBordered = false
        close.tag = tool.rawValue
        let heading = padded(stack([label(tool.title, weight: .semibold), NSView(), close], vertical: false), height: 38)
        let container = stack([heading, panel.view], vertical: true)
        pin(container, to: self)
        current = container
        self.tool = tool
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
