import AppKit
import UITheme

/// The window's root view. Composes tool rails, panel surfaces, editor, toolbar and status bar.
/// It presents layout values and reports user actions without owning the layout model.
@MainActor
public final class WorkspaceView: NSView {
    var onSelectTool: ((WorkspaceTool) -> Void)?
    var onToggleFocusEditor: (() -> Void)?
    var onFocusEditor: (() -> Void)?
    var onResetLayout: (() -> Void)?
    var onProjectMenu: (() -> NSMenu)?
    var onSizeChange: (() -> Void)?
    var isProjectMenuEnabled = false { didSet { projectSwitcher.isEnabled = isProjectMenuEnabled } }
    var leadingHeaderInset: CGFloat = 12 { didSet { headerLeading?.constant = leadingHeaderInset } }

    let notificationOverlay: WorkspaceNotificationOverlay
    private let left = WorkspacePanelView()
    private let right = WorkspacePanelView()
    private let bottom = WorkspacePanelView()
    lazy var leftSurface = workspaceSurface(left)
    lazy var rightSurface = workspaceSurface(right)
    lazy var bottomSurface = workspaceSurface(bottom)
    let editorSurface: NSView
    private let panels: [WorkspaceTool: WorkspacePanel]
    private let leftRail: WorkspaceToolRailView
    private let rightRail: WorkspaceToolRailView
    var buttons: [WorkspaceTool: NSButton] { leftRail.buttons.merging(rightRail.buttons) { first, _ in first } }
    private let projectBadge: ProjectBadgeView
    private let projectLabel = NSTextField(labelWithString: "")
    private let projectSwitcher = NSButton()
    private let projectAccessory = NSStackView()
    private let detailLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let pathLabel = NSTextField(labelWithString: "")
    private var headerLeading: NSLayoutConstraint?
    private var headerBar: NSView?
    private var headerProject: NSStackView?
    private var headerFocus: NSButton?
    private var headerReset: NSButton?
    private var windowToolbar: WorkspaceWindowToolbar?
    private var contentTop: NSLayoutConstraint?
    private var chrome: [NSView] = []
    private var lastSize: NSSize = .zero

    init(
        editor: NSView,
        content: NSView,
        panels: [WorkspaceTool: WorkspacePanel],
        available: Set<WorkspaceTool>,
        project: String,
        path: String,
        notifications: WorkspaceNotifications
    ) {
        self.panels = panels
        projectBadge = ProjectBadgeView(name: project)
        leftRail = WorkspaceToolRailView(leftSide: true, available: available, provided: Set(panels.keys))
        rightRail = WorkspaceToolRailView(leftSide: false, available: available, provided: Set(panels.keys))
        editorSurface = workspaceSurface(editor, role: .editor)
        notificationOverlay = WorkspaceNotificationOverlay(notifications: notifications)
        super.init(frame: NSRect(x: 0, y: 0, width: 1280, height: 820))
        projectLabel.stringValue = project
        projectLabel.toolTip = path
        pathLabel.stringValue = path
        pathLabel.toolTip = path
        workspacePin(WorkspaceBackgroundView(role: .chrome, accent: ProjectIdentity.colour(for: project)), to: self)
        workspacePin(notificationOverlay, to: editorSurface)
        notificationOverlay.restoreFocus = { [weak self] in self?.onFocusEditor?() }
        for rail in [leftRail, rightRail] {
            rail.onSelectTool = { [weak self] tool in self?.onSelectTool?(tool) }
        }
        for panel in [left, right, bottom] {
            panel.onHide = { [weak self] tool in self?.onSelectTool?(tool) }
        }
        let topBar = toolbar(), status = statusBar()
        chrome = [leftRail, rightRail, topBar, status]
        let body = workspaceStack(
            [leftRail, content, rightRail],
            vertical: false,
            insets: NSEdgeInsets(top: 2, left: 2, bottom: 2, right: 2)
        )
        contentTop = workspacePin(workspaceStack([topBar, body, status], vertical: true), to: self)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func layout() {
        super.layout()
        guard lastSize != bounds.size else { return }

        lastSize = bounds.size
        onSizeChange?()
    }

    func present(layout: WorkspaceLayout, isFocused: Bool) {
        for item in chrome { item.isHidden = isFocused }
        if let windowToolbar {
            headerBar?.isHidden = true
            if windowToolbar.toolbar.isVisible == isFocused {
                windowToolbar.toolbar.isVisible = !isFocused
            }
        }

        if let tool = layout.left, let panel = panels[tool] { left.show(panel, tool: tool) }
        if let tool = layout.right, let panel = panels[tool] { right.show(panel, tool: tool) }
        if let tool = layout.bottom, let panel = panels[tool] { bottom.show(panel, tool: tool) }
        leftRail.present(layout)
        rightRail.present(layout)
    }

    func present(detail: String?, status: String?) {
        detailLabel.stringValue = detail ?? ""
        detailLabel.toolTip = detail
        statusLabel.stringValue = status ?? ""
        statusLabel.toolTip = status
    }

    func disconnect() {
        notificationOverlay.disconnect()
        windowToolbar?.toolbar.delegate = nil
        onSelectTool = nil
        onToggleFocusEditor = nil
        onFocusEditor = nil
        onResetLayout = nil
        onProjectMenu = nil
        onSizeChange = nil
    }

    /// AppKit owns the titlebar height and aligns the window controls with these items.
    func installWindowToolbar(on window: NSWindow) {
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
    }

    func installProjectAccessory(_ control: NSView?) {
        for old in projectAccessory.arrangedSubviews {
            projectAccessory.removeArrangedSubview(old)
            old.removeFromSuperview()
        }
        if let control { projectAccessory.addArrangedSubview(control) }
    }

    private func toolbar() -> NSView {
        projectLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        projectLabel.textColor = WorkspaceTheme.chromeForeground
        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.textColor = WorkspaceTheme.chromeSecondaryForeground
        projectLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.lineBreakMode = .byTruncatingTail
        projectLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let focus = NSButton(title: "Focus Editor", target: self, action: #selector(toggleFocusEditor(_:)))
        let reset = NSButton(title: "Reset Layout", target: self, action: #selector(resetLayout(_:)))

        projectSwitcher.title = ""
        projectSwitcher.target = self
        projectSwitcher.action = #selector(showProjectMenu(_:))
        projectSwitcher.image = WorkspaceIcon.image("chevron.down", description: "Switch project")
        projectSwitcher.contentTintColor = WorkspaceTheme.chromeSecondaryForeground
        projectSwitcher.isBordered = false
        projectSwitcher.toolTip = "Open and recent projects"
        projectSwitcher.isEnabled = isProjectMenuEnabled

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
        onProjectMenu?().popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
    }

    @objc private func toggleFocusEditor(_ sender: NSButton) { onToggleFocusEditor?() }

    @objc private func resetLayout(_ sender: NSButton) { onResetLayout?() }

    private func statusBar() -> NSView {
        for field in [pathLabel, statusLabel] {
            field.font = .systemFont(ofSize: 11)
            field.textColor = WorkspaceTheme.chromeSecondaryForeground
            field.lineBreakMode = .byTruncatingMiddle
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }

        return workspacePadded(
            workspaceStack([pathLabel, NSView(), statusLabel], vertical: false, spacing: 12),
            height: 28
        )
    }
}

/// Empty header space drags the window, as the native titlebar does.
@MainActor
private final class ChromeBarView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
}
