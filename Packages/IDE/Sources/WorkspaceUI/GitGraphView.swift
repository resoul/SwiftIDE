import AppKit
import IDEApplication

@MainActor
final class GitGraphView: NSView {
    let row: GitGraphRow
    override var isFlipped: Bool { true }

    init(row: GitGraphRow) {
        self.row = row
        super.init(frame: .zero)
        setAccessibilityElement(false)
        if row.lanes > 20 {
            toolTip = "Graph exceeds 20 visible lanes; select a commit for its complete parent IDs."
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        let palette: [NSColor] = [.systemBlue, .systemPurple, .systemGreen, .systemOrange, .systemPink, .systemTeal]
        let middle = bounds.height / 2

        func x(_ lane: Int) -> CGFloat { 8 + CGFloat(lane) * 14 }

        for edge in row.edges {
            let path = NSBezierPath()
            path.move(to: NSPoint(x: x(edge.from), y: edge.incoming ? 0 : middle))
            path.line(to: NSPoint(x: x(edge.to), y: edge.incoming ? middle : bounds.height))
            path.lineWidth = 1.5
            palette[edge.colour % palette.count].setStroke()
            path.stroke()
        }
        palette[row.colour % palette.count].setFill()
        NSBezierPath(ovalIn: NSRect(x: x(row.lane) - 4, y: middle - 4, width: 8, height: 8)).fill()
    }
}
