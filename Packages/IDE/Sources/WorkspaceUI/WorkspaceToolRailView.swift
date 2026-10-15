import AppKit
import UITheme

/// A tool rail presents availability and selection, and reports clicks to its owner.
@MainActor
final class WorkspaceToolRailView: NSView {
    var onSelectTool: ((WorkspaceTool) -> Void)?
    private(set) var buttons: [WorkspaceTool: NSButton] = [:]
    private let tools: [WorkspaceTool]

    init(leftSide: Bool, available: Set<WorkspaceTool>, provided: Set<WorkspaceTool>) {
        let registered = Set(WorkspaceTool.allCases).union(available).sorted { $0.rawValue < $1.rawValue }
        tools = registered.filter { $0.zone == (leftSide ? .left : .right) || (leftSide && $0.zone == .bottom) }
        super.init(frame: .zero)
        var views: [NSView] = []
        for tool in tools where tool.zone != .bottom {
            views.append(toolButton(tool, enabled: available.contains(tool) && provided.contains(tool)))
        }
        views.append(NSView())
        for tool in tools where tool.zone == .bottom {
            views.append(toolButton(tool, enabled: available.contains(tool) && provided.contains(tool)))
        }
        let content = workspaceStack(
            views,
            vertical: true,
            spacing: 8,
            insets: NSEdgeInsets(top: 10, left: 6, bottom: 10, right: 6)
        )
        workspacePin(content, to: self)
        widthAnchor.constraint(equalToConstant: 44).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func present(_ layout: WorkspaceLayout) {
        for (tool, button) in buttons {
            let selected = layout.contains(tool)
            (button as? RailButton)?.isActive = selected
            button.setAccessibilityValue(button.isEnabled ? (selected ? "Selected" : "Hidden") : "Unavailable")
        }
    }

    private func toolButton(_ tool: WorkspaceTool, enabled: Bool) -> NSButton {
        let button = RailButton(title: "", target: self, action: #selector(selectTool(_:)))
        button.image = WorkspaceIcon.image(tool.symbol, description: tool.title)
        button.tag = tool.rawValue
        button.isBordered = false
        button.isEnabled = enabled
        button.toolTip = enabled ? tool.title : tool.title + " — not available yet"
        button.setAccessibilityLabel(button.toolTip)
        button.widthAnchor.constraint(equalToConstant: 32).isActive = true
        button.heightAnchor.constraint(equalToConstant: 32).isActive = true
        buttons[tool] = button

        return button
    }

    @objc private func selectTool(_ sender: NSButton) {
        guard let tool = tools.first(where: { $0.rawValue == sender.tag }) else { return }

        onSelectTool?(tool)
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
            if isActive {
                layer?.backgroundColor = NSColor.controlAccentColor.cgColor
                contentTintColor = WorkspaceTheme.chromeForeground
            } else if hovered, isEnabled {
                layer?.backgroundColor = WorkspaceTheme.chromeHoverBackground.cgColor
                contentTintColor = WorkspaceTheme.chromeForeground
            } else {
                layer?.backgroundColor = NSColor.clear.cgColor
                contentTintColor = isEnabled
                    ? WorkspaceTheme.chromeSecondaryForeground
                    : WorkspaceTheme.chromeDisabledForeground
            }
        }
    }
}
