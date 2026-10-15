import AppKit

/// A caller-provided tool view. The workspace retains its view and focus target across panel switches.
@MainActor
public struct WorkspacePanel {
    public let view: NSView
    public let focusTarget: NSView?

    public init(view: NSView, focusTarget: NSView? = nil) {
        self.view = view
        self.focusTarget = focusTarget
    }
}
