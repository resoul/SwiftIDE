import AppKit

/// Connects workspace state and user actions to the root WorkspaceView.
/// Native split controllers retain their AppKit lifecycle and divider behavior.
@MainActor
public final class WorkspaceViewController: NSViewController {
    public let state: WorkspaceLayoutState
    public let notifications: WorkspaceNotifications
    public var editorFocus: NSView?
    public var projectMenu: (() -> NSMenu)? {
        didSet { content?.isProjectMenuEnabled = projectMenu != nil }
    }
    public var leadingHeaderInset: CGFloat = 12 {
        didSet { content?.leadingHeaderInset = leadingHeaderInset }
    }
    let horizontal = NSSplitViewController()
    let vertical = NSSplitViewController()
    var buttons: [WorkspaceTool: NSButton] { content?.buttons ?? [:] }
    var notificationOverlay: WorkspaceNotificationOverlay? { content?.notificationOverlay }
    private let editor: NSView
    private let panels: [WorkspaceTool: WorkspacePanel]
    private let project: String
    private let path: String
    private var content: WorkspaceView?
    private var leftItem: NSSplitViewItem!
    private var rightItem: NSSplitViewItem!
    private var bottomItem: NSSplitViewItem!
    private var subscription: UUID?
    private var isUpdatingLayout = false

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
        self.project = project
        self.path = path
        super.init(nibName: nil, bundle: nil)
        subscription = state.subscribe { [weak self] in self?.render() }
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func loadView() {
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
        let content = WorkspaceView(
            editor: editor,
            content: vertical.view,
            panels: panels,
            available: state.available,
            project: project,
            path: path,
            notifications: notifications
        )
        self.content = content
        view = content
        content.leadingHeaderInset = leadingHeaderInset
        content.isProjectMenuEnabled = projectMenu != nil
        content.onSelectTool = { [weak self] in self?.select($0) }
        content.onToggleFocusEditor = { [weak self] in self?.toggleFocusEditor(nil) }
        content.onFocusEditor = { [weak self] in self?.focusEditor() }
        content.onResetLayout = { [weak self] in self?.resetWorkspaceLayout(nil) }
        content.onProjectMenu = { [weak self] in self?.projectMenu?() ?? NSMenu() }
        addChild(vertical)
        leftItem = NSSplitViewItem(viewController: controller(content.leftSurface))
        leftItem.canCollapse = true
        leftItem.minimumThickness = 200
        leftItem.maximumThickness = 440
        let centre = NSSplitViewItem(viewController: controller(content.editorSurface))
        centre.minimumThickness = 360
        rightItem = NSSplitViewItem(viewController: controller(content.rightSurface))
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
        bottomItem = NSSplitViewItem(viewController: controller(content.bottomSurface))
        bottomItem.canCollapse = true
        bottomItem.minimumThickness = 140
        bottomItem.maximumThickness = 380
        vertical.addSplitViewItem(top)
        vertical.addSplitViewItem(bottomItem)
        content.onSizeChange = { [weak self] in self?.render() }
        render()
    }

    public override func viewWillAppear() {
        super.viewWillAppear()
        render()
    }

    public func installWindowToolbar(on window: NSWindow) {
        loadViewIfNeeded()
        content?.installWindowToolbar(on: window)
        render()
    }

    public func installProjectAccessory(_ control: NSView?) {
        loadViewIfNeeded()
        content?.installProjectAccessory(control)
    }

    /// Updates never alter focus, panel selection or an editor's text.
    public func present(detail: String?, status: String?) {
        loadViewIfNeeded()
        content?.present(detail: detail, status: status)
    }

    public func disconnect() {
        content?.disconnect()
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

    private func render() {
        guard isViewLoaded, !isUpdatingLayout else { return }

        isUpdatingLayout = true
        defer { isUpdatingLayout = false }
        let layout = state.layout
        content?.present(layout: layout, isFocused: state.isFocused)
        leftItem.isCollapsed = layout.left == nil
        rightItem.isCollapsed = layout.right == nil
        bottomItem.isCollapsed = layout.bottom == nil
        view.layoutSubtreeIfNeeded()
        if layout.left != nil { horizontal.splitView.setPosition(layout.leftWidth, ofDividerAt: 0) }
        if layout.right != nil {
            horizontal.splitView.setPosition(horizontal.view.bounds.width - layout.rightWidth, ofDividerAt: 1)
        }

        if layout.bottom != nil {
            vertical.splitView.setPosition(vertical.view.bounds.height - layout.bottomHeight, ofDividerAt: 0)
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

}

@MainActor
private func controller(_ view: NSView) -> NSViewController {
    let result = NSViewController()
    result.view = view

    return result
}
