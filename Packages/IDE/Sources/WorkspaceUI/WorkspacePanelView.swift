import AppKit

/// Retains the supplied tool view while its heading and hide action belong to the workspace.
@MainActor
final class WorkspacePanelView: NSView {
    var onHide: ((WorkspaceTool) -> Void)?
    private var current: NSView?
    private var tool: WorkspaceTool?

    func show(_ panel: WorkspacePanel, tool: WorkspaceTool) {
        guard self.tool != tool else { return }

        current?.removeFromSuperview()
        let close = NSButton(title: "", target: self, action: #selector(hidePanel(_:)))
        close.image = WorkspaceIcon.image("minus", description: "Hide " + tool.title)
        close.isBordered = false
        let heading = workspacePadded(
            workspaceStack([workspaceLabel(tool.title, weight: .semibold), NSView(), close], vertical: false),
            height: 38
        )
        let container = workspaceStack([heading, panel.view], vertical: true)
        workspacePin(container, to: self)
        current = container
        self.tool = tool
    }

    @objc private func hidePanel(_ sender: NSButton) {
        if let tool { onHide?(tool) }
    }
}
