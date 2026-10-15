import AppKit

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
