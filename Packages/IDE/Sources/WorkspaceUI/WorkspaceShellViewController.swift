import AppKit
import UITheme

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
    public let notifications: WorkspaceNotifications
    private(set) var notificationOverlay: WorkspaceNotificationOverlay?
    let horizontal = NSSplitViewController()
    let vertical = NSSplitViewController()
    private let left = ShellPanel()
    private let right = ShellPanel()
    private let bottom = ShellPanel()
    private let editor: NSView
    public var editorFocus: NSView?
    private let panels: [WorkspaceTool: WorkspacePanel]
    private var leftItem: NSSplitViewItem!
    private var rightItem: NSSplitViewItem!
    private var bottomItem: NSSplitViewItem!
    private(set) var buttons: [WorkspaceTool: NSButton] = [:]
    private let projectBadge: ProjectBadgeView
    private let projectAccent: NSColor
    private let projectLabel = NSTextField(labelWithString: "")
    private let projectSwitcher = NSButton()
    private let projectAccessory = NSStackView()
    public var projectMenu: (() -> NSMenu)? { didSet { projectSwitcher.isEnabled = projectMenu != nil } }

    public var leadingHeaderInset: CGFloat = 12 { didSet { headerLeading?.constant = leadingHeaderInset } }
    private var headerLeading: NSLayoutConstraint?
    private var headerBar: NSView?
    private var headerProject: NSStackView?
    private var headerFocus: NSButton?
    private var headerReset: NSButton?
    private var windowToolbar: WorkspaceWindowToolbar?
    private var contentTop: NSLayoutConstraint?

    /// AppKit owns the titlebar height and aligns the window controls with these items.
    public func installWindowToolbar(on window: NSWindow) {
        _ = view
        guard windowToolbar == nil, let headerProject, let headerFocus, let headerReset else { return }

        let controls: [NSView] = [headerProject, detailLabel, headerFocus, headerReset]
        for control in controls {
            (control.superview as? NSStackView)?.removeArrangedSubview(control)
            control.removeFromSuperview()
        }
        let native = WorkspaceWindowToolbar(
            project: headerProject,
            detail: detailLabel,
            focus: headerFocus,
            reset: headerReset
        )
        windowToolbar = native
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.toolbarStyle = .unified
        window.toolbar = native.toolbar
        if let guide = window.contentLayoutGuide as? NSLayoutGuide,
           let content = contentTop?.firstItem as? NSView {
            contentTop?.isActive = false
            contentTop = content.topAnchor.constraint(equalTo: guide.topAnchor)
            contentTop?.isActive = true
        }

        render()
    }

    public func installProjectAccessory(_ control: NSView?) {
        for old in projectAccessory.arrangedSubviews {
            projectAccessory.removeArrangedSubview(old)
            old.removeFromSuperview()
        }
        if let control { projectAccessory.addArrangedSubview(control) }
    }

    private let detailLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let pathLabel = NSTextField(labelWithString: "")
    private var subscription: UUID?
    private var isUpdatingLayout = false
    private var lastSize: NSSize = .zero
    private var chrome: [NSView] = []

    public init(
        state: WorkspaceLayoutState,
        editor: NSView,
        editorFocus: NSView? = nil,
        panels: [WorkspaceTool: WorkspacePanel],
        project: String,
        path: String,
        notifications: WorkspaceNotifications = WorkspaceNotifications()
    ) {
        self.state = state
        self.notifications = notifications
        self.editor = editor
        self.editorFocus = editorFocus
        self.panels = panels
        projectBadge = ProjectBadgeView(name: project)
        projectAccent = ProjectIdentity.colour(for: project)
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
        view = WorkspaceBackgroundView(role: .chrome, accent: projectAccent)
        view.frame = NSRect(x: 0, y: 0, width: 1280, height: 820)
        let horizontalSplit = WorkspaceSplitView()
        horizontalSplit.onDividerDrag = { [weak self] before in
            self?.rememberDraggedSizes(before: before, vertical: false)
        }
        horizontal.splitView = horizontalSplit
        let verticalSplit = WorkspaceSplitView()
        verticalSplit.onDividerDrag = { [weak self] before in
            self?.rememberDraggedSizes(before: before, vertical: true)
        }
        vertical.splitView = verticalSplit
        horizontal.splitView.isVertical = true
        horizontal.splitView.dividerStyle = .thin
        leftItem = NSSplitViewItem(viewController: controller(surface(left)))
        leftItem.canCollapse = true
        leftItem.minimumThickness = 200
        leftItem.maximumThickness = 440
        let editorSurface = surface(editor, role: .editor)
        let overlay = WorkspaceNotificationOverlay(notifications: notifications)
        overlay.restoreFocus = { [weak self] in self?.focusEditor() }
        pin(overlay, to: editorSurface)
        notificationOverlay = overlay
        let centre = NSSplitViewItem(viewController: controller(editorSurface))
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
        let leftRail = rail(leftSide: true), rightRail = rail(leftSide: false)
        let topBar = toolbar(), status = statusBar()
        chrome = [leftRail, rightRail, topBar, status]

        let body = stack(
            [leftRail, vertical.view, rightRail],
            vertical: false,
            insets: NSEdgeInsets(top: 2, left: 2, bottom: 2, right: 2)
        )
        contentTop = pin(stack([topBar, body, status], vertical: true), to: view)
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
        notificationOverlay?.disconnect()
        windowToolbar?.toolbar.delegate = nil
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

        projectSwitcher.title = ""
        projectSwitcher.target = self
        projectSwitcher.action = #selector(showProjectMenu(_:))
        projectSwitcher.image = WorkspaceIcon.image("chevron.down", description: "Switch project")
        projectSwitcher.isBordered = false
        projectSwitcher.toolTip = "Open and recent projects"
        projectSwitcher.isEnabled = projectMenu != nil

        let project = NSStackView(views: [
            projectBadge,
            projectLabel,
            projectSwitcher,
            projectAccessory
        ])
        project.orientation = .horizontal
        project.alignment = .centerY
        project.spacing = 8
        headerProject = project
        headerFocus = focus
        headerReset = reset
        let content = NSStackView(views: [
            project,
            NSView(),
            detailLabel,
            focus,
            reset
        ])
        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = 8
        projectAccessory.alignment = .centerY
        let bar = ChromeBarView()
        headerBar = bar
        bar.addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        let leading = content.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: leadingHeaderInset)
        headerLeading = leading

        NSLayoutConstraint.activate([
            leading,
            content.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -12),
            content.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            bar.heightAnchor.constraint(equalToConstant: 36)
        ])

        return bar
    }

    @objc private func showProjectMenu(_ sender: NSButton) {
        projectMenu?().popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
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
        let registered = Set(WorkspaceTool.allCases).union(state.available).sorted { $0.rawValue < $1.rawValue }
        let tools = registered.filter { $0.zone == (leftSide ? .left : .right) }
        for tool in tools { views.append(toolButton(tool)) }
        views.append(NSView())
        if leftSide {
            for tool in registered where tool.zone == .bottom { views.append(toolButton(tool)) }
        }

        let rail = stack(
            views,
            vertical: true,
            spacing: 8,
            insets: NSEdgeInsets(top: 10, left: 6, bottom: 10, right: 6)
        )
        rail.widthAnchor.constraint(equalToConstant: 44).isActive = true

        return rail
    }

    private func toolButton(_ tool: WorkspaceTool) -> NSButton {
        let button = RailButton(title: "", target: self, action: #selector(selectTool(_:)))
        button.image = WorkspaceIcon.image(tool.symbol, description: tool.title)
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
        guard let tool = state.available.first(where: { $0.rawValue == sender.tag }) else { return }

        select(tool)
    }

    private func render() {
        guard isViewLoaded, !isUpdatingLayout else { return }

        isUpdatingLayout = true
        defer { isUpdatingLayout = false }
        let layout = state.layout
        for item in chrome { item.isHidden = state.isFocused }
        if let windowToolbar {
            headerBar?.isHidden = true
            if windowToolbar.toolbar.isVisible == state.isFocused {
                windowToolbar.toolbar.isVisible = !state.isFocused
            }
        }

        leftItem.isCollapsed = layout.left == nil
        rightItem.isCollapsed = layout.right == nil
        bottomItem.isCollapsed = layout.bottom == nil
        if let tool = layout.left, let panel = panels[tool] { left.show(panel, tool: tool, target: self) }
        if let tool = layout.right, let panel = panels[tool] { right.show(panel, tool: tool, target: self) }
        if let tool = layout.bottom, let panel = panels[tool] { bottom.show(panel, tool: tool, target: self) }
        view.layoutSubtreeIfNeeded()
        if layout.left != nil { horizontal.splitView.setPosition(layout.leftWidth, ofDividerAt: 0) }
        if layout.right != nil {
            horizontal.splitView.setPosition(horizontal.view.bounds.width - layout.rightWidth, ofDividerAt: 1)
        }

        if layout.bottom != nil {
            vertical.splitView.setPosition(vertical.view.bounds.height - layout.bottomHeight, ofDividerAt: 0)
        }

        for (tool, button) in buttons {
            let selected = layout.contains(tool)
            (button as? RailButton)?.isActive = selected
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
            right: !vertical && !rightItem.isCollapsed && abs(after[after.count - 1] - before[before.count - 1]) > 1
                ? after[after.count - 1]
                : nil,
            bottom: vertical && !bottomItem.isCollapsed && abs(after[1] - before[1]) > 1 ? after[1] : nil
        )
    }

    @objc fileprivate func hidePanel(_ sender: NSButton) {
        guard let tool = state.available.first(where: { $0.rawValue == sender.tag }) else { return }

        select(tool)
    }
}

@MainActor
final class WorkspaceSplitView: NSSplitView {
    var onDividerDrag: (([CGFloat]) -> Void)?

    override var dividerThickness: CGFloat { 2 }

    override func drawDivider(in rect: NSRect) {}

    override func mouseDown(with event: NSEvent) {
        let before = subviews.map { isVertical ? $0.frame.width : $0.frame.height }
        super.mouseDown(with: event)
        onDividerDrag?(before)
    }
}

/// A tool-strip button with three visible states: normal, hover and active (its panel is open).
@MainActor
private final class RailButton: NSButton {
    var isActive = false { didSet { refresh() } }
    private var hovered = false { didSet { refresh() } }

    override var isEnabled: Bool {
        didSet { refresh() }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }

    override func mouseExited(with event: NSEvent) { hovered = false }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
    }

    /// Colours are set directly, not in updateLayer, so NSButton still draws its image.
    private func refresh() {
        wantsLayer = true
        layer?.cornerRadius = 8
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            if isActive {
                layer?.backgroundColor = NSColor.controlAccentColor.cgColor
                contentTintColor = .white
            } else if hovered, isEnabled {
                layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(dark ? 0.12 : 0.08).cgColor
                contentTintColor = .labelColor
            } else {
                layer?.backgroundColor = NSColor.clear.cgColor
                contentTintColor = isEnabled ? .secondaryLabelColor : .tertiaryLabelColor
            }
        }
    }
}

/// The header row. Empty space in it drags the window, as the titlebar does when the content runs under it.
@MainActor
private final class ChromeBarView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
}

@MainActor
private final class ShellPanel: NSView {
    private var current: NSView?
    private var tool: WorkspaceTool?

    func show(_ panel: WorkspacePanel, tool: WorkspaceTool, target: WorkspaceShellViewController) {
        guard self.tool != tool else { return }

        current?.removeFromSuperview()
        let close = NSButton(title: "", target: target, action: #selector(WorkspaceShellViewController.hidePanel(_:)))
        close.image = WorkspaceIcon.image("minus", description: "Hide " + tool.title)
        close.isBordered = false
        close.tag = tool.rawValue
        let heading = padded(
            stack([label(tool.title, weight: .semibold), NSView(), close], vertical: false),
            height: 38
        )
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
private func stack(
    _ views: [NSView],
    vertical: Bool,
    spacing: CGFloat = 0,
    insets: NSEdgeInsets = NSEdgeInsets()
) -> NSStackView {
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
            $0.heightAnchor.constraint(equalTo: view.heightAnchor, constant: -insets.top - insets.bottom)
                .isActive = true
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
@discardableResult
private func pin(_ view: NSView, to parent: NSView) -> NSLayoutConstraint {
    parent.addSubview(view)
    view.translatesAutoresizingMaskIntoConstraints = false
    let top = view.topAnchor.constraint(equalTo: parent.topAnchor)
    NSLayoutConstraint.activate([
        view.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
        view.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
        top,
        view.bottomAnchor.constraint(equalTo: parent.bottomAnchor)
    ])

    return top
}

@MainActor
private final class WorkspaceBackgroundView: NSView {
    enum Role { case chrome, panel, editor }

    private let role: Role
    private let accent: NSColor?
    private let tint: CAGradientLayer?

    init(role: Role, accent: NSColor? = nil) {
        self.role = role
        self.accent = accent
        tint = accent == nil ? nil : CAGradientLayer()
        super.init(frame: .zero)
        wantsLayer = true
        if role != .chrome {
            layer?.cornerRadius = 10
            layer?.masksToBounds = true
        }

        if let tint {
            tint.startPoint = CGPoint(x: 0, y: 1)
            tint.endPoint = CGPoint(x: 0.8, y: 0.2)
            layer?.addSublayer(tint)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tint?.frame = bounds
        CATransaction.commit()
    }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let background: NSColor
            switch role {
            case .chrome: background = WorkspaceTheme.chromeBackground
            case .panel, .editor: background = WorkspaceTheme.background
            }

            layer?.backgroundColor = background.cgColor

            if let accent, let tint {
                tint.colors = [
                    accent.withAlphaComponent(WorkspaceTheme.chromeTintOpacity(in: effectiveAppearance)).cgColor,
                    accent.withAlphaComponent(0).cgColor
                ]
            }
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
        card.leadingAnchor.constraint(equalTo: outer.leadingAnchor, constant: 1),
        card.trailingAnchor.constraint(equalTo: outer.trailingAnchor, constant: -1),
        card.topAnchor.constraint(equalTo: outer.topAnchor, constant: 1),
        card.bottomAnchor.constraint(equalTo: outer.bottomAnchor, constant: -1)
    ])

    return outer
}
