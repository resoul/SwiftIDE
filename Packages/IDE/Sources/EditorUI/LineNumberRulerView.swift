import AppKit
import IDEApplication
import IDEDomain

/// Line numbers in the margin of the editor's scroll view.
///
/// Numbers come from the document's line index, not from layout, so they are right for lines
/// that have not been laid out and cost nothing proportional to the file. Only the fragments in
/// view are visited, and a wrapped line carries its number on its first row only.
@MainActor
public final class LineNumberRulerView: NSRulerView {
    /// One number to draw: where the first row of its line sits, in this view's coordinates.
    public struct Label: Equatable {
        public let number: Int
        public let baseline: CGFloat
    }

    /// The worst problem on each line (zero-based), drawn as a dot beside the number.
    public var problemLines: [Int: DocumentDiagnostic.Severity] = [:] {
        didSet { if problemLines != oldValue { needsDisplay = true } }
    }

    /// The lines (zero-based) where a foldable region starts, and whether it is folded now. The
    /// arrow of a folded one is always drawn; the others show while the pointer is over the margin.
    public var foldMarks: [Int: Bool] = [:] {
        didSet { if foldMarks != oldValue { needsDisplay = true } }
    }

    /// Whether the margin has a column for fold arrows.
    public var showsFolding = false {
        didSet { if showsFolding != oldValue { updateThickness() } }
    }

    /// The arrow of the region that starts on this line (zero-based) was clicked.
    public var onToggleFold: (@MainActor (Int) -> Void)?

    private var isPointerInside = false

    /// The pointer is on the row of a line that has a problem (its zero-based number), or left it (nil).
    public var onProblemHover: (@MainActor (Int?) -> Void)?

    private var hoveredLine: Int?
    private var trackingArea: NSTrackingArea?
    private let textView: NSTextView
    private let lineIndex: DocumentLineIndex
    private let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
    private var observers: [NSObjectProtocol] = []
    private var indexSubscription: UUID?

    public init(scrollView: NSScrollView, textView: NSTextView, lineIndex: DocumentLineIndex) {
        self.textView = textView
        self.lineIndex = lineIndex
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        // The numbers of lines scrolled partly out of view must not be drawn above the margin.
        clipsToBounds = true
        reservedThicknessForMarkers = 0
        updateThickness()

        indexSubscription = lineIndex.subscribe { [weak self] in
            self?.updateThickness()
            self?.needsDisplay = true
        }
        // Scrolling and re-wrapping move the rows without changing the text.
        scrollView.contentView.postsBoundsChangedNotifications = true
        textView.postsFrameChangedNotifications = true
        for (name, object) in [
            (NSView.boundsDidChangeNotification, scrollView.contentView as NSView),
            (NSView.frameDidChangeNotification, textView as NSView)
        ] {
            observers.append(NotificationCenter.default.addObserver(
                forName: name,
                object: object,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.needsDisplay = true }
            })
        }
    }

    @available(*, unavailable)
    public required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    isolated deinit {
        if let indexSubscription { lineIndex.unsubscribe(indexSubscription) }
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    // MARK: Pointer

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }

        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    public override func mouseEntered(with event: NSEvent) {
        isPointerInside = true
        if !foldMarks.isEmpty { needsDisplay = true }
    }

    public override func mouseMoved(with event: NSEvent) {
        pointerMoved(toY: convert(event.locationInWindow, from: nil).y)
    }

    public override func mouseExited(with event: NSEvent) {
        isPointerInside = false
        if !foldMarks.isEmpty { needsDisplay = true }

        pointerMoved(toY: nil)
    }

    public override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let line = foldLine(atX: point.x, y: point.y) {
            onToggleFold?(line)
        } else {
            super.mouseDown(with: event)
        }
    }

    /// The line whose fold arrow is at this point of the margin, if there is one.
    public func foldLine(atX x: CGFloat, y: CGFloat) -> Int? {
        guard showsFolding, x >= bounds.maxX - Self.foldColumnWidth - 1 else { return nil }

        let font = textView.font ?? self.font
        let above = font.ascender, below = -font.descender + font.leading
        guard let label = visibleLabels().first(where: { y >= $0.baseline - above && y <= $0.baseline + below }),
              foldMarks[label.number - 1] != nil else { return nil }

        return label.number - 1
    }

    /// The pointer is at height `y` of this view, or outside it. Only the first row of a line with a
    /// problem counts; the owner is told when that changes.
    func pointerMoved(toY y: CGFloat?) {
        var line: Int?
        if let y {
            let font = textView.font ?? self.font
            let above = font.ascender, below = -font.descender + font.leading
            if let label = visibleLabels().first(where: { y >= $0.baseline - above && y <= $0.baseline + below }),
               problemLines[label.number - 1] != nil {
                line = label.number - 1
            }
        }

        guard line != hoveredLine else { return }

        hoveredLine = line
        onProblemHover?(line)
    }

    // MARK: Width

    private func updateThickness() {
        let digits = max(3, String(lineIndex.index.lineCount).count)
        let digitWidth = ("0" as NSString).size(withAttributes: [.font: font]).width
        let wanted = ceil(CGFloat(digits) * digitWidth) + 16 + (showsFolding ? Self.foldColumnWidth : 0)
        if abs(ruleThickness - wanted) > 0.5 { ruleThickness = wanted }
    }

    // MARK: Content

    /// The numbers of the lines whose first row is in view, top to bottom.
    public func visibleLabels() -> [Label] {
        guard let layoutManager = textView.textLayoutManager,
              let content = layoutManager.textContentManager else { return [] }

        let index = lineIndex.current
        let origin = textView.textContainerOrigin
        let visible = textView.visibleRect
        let start = layoutManager.textViewportLayoutController.viewportRange?.location
            ?? layoutManager.documentRange.location

        var labels: [Label] = []

        func baseline(of row: NSTextLineFragment, in frame: CGRect) -> CGFloat {
            let inText = frame.minY + row.typographicBounds.minY + row.glyphOrigin.y + origin.y

            return convert(NSPoint(x: 0, y: inText), from: textView).y
        }

        let documentEnd = index.utf16Length
        layoutManager.enumerateTextLayoutFragments(from: start, options: [.ensuresLayout]) { fragment in
            let frame = fragment.layoutFragmentFrame
            if frame.minY + origin.y > visible.maxY { return false }
            guard frame.maxY + origin.y >= visible.minY, let row = fragment.textLineFragments.first else {
                return true
            }

            let offset = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
            if let line = index.lineStarting(at: offset) {
                labels.append(Label(number: line + 1, baseline: baseline(of: row, in: frame)))
            }

            // After a final line break the layout adds an empty row to the last fragment: that
            // row is the document's last, empty line.
            let end = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.endLocation)
            if end == documentEnd, fragment.textLineFragments.count > 1, let extra = fragment.textLineFragments.last,
               index.lineStarting(at: documentEnd) == index.lineCount - 1 {
                labels.append(Label(number: index.lineCount, baseline: baseline(of: extra, in: frame)))
            }

            return true
        }
        // An empty document has no fragment at all; its one row is where the insertion point is.
        if documentEnd == 0 {
            var top: CGFloat?
            layoutManager.enumerateTextSegments(
                in: NSTextRange(location: layoutManager.documentRange.endLocation),
                type: .standard,
                options: []
            ) { _, rect, _, _ in
                top = rect.minY

                return false
            }
            if let top, let font = textView.font {
                let inText = top + origin.y + ceil(font.ascender)
                labels.append(Label(number: 1, baseline: convert(NSPoint(x: 0, y: inText), from: textView).y))
            }
        }

        return labels
    }

    static let markerSize: CGFloat = 6
    static let foldColumnWidth: CGFloat = 14

    static func colour(for severity: DocumentDiagnostic.Severity) -> NSColor {
        switch severity {
        case .error: .systemRed
        case .warning: .systemYellow
        case .information, .hint: .systemGray
        }
    }

    private func drawFoldArrow(collapsed: Bool, centreY: CGFloat) {
        let centreX = bounds.maxX - Self.foldColumnWidth / 2 - 1
        let half: CGFloat = 3.5
        let path = NSBezierPath()
        if collapsed {
            // Pointing right: there is more below.
            path.move(to: NSPoint(x: centreX - half / 2, y: centreY - half))
            path.line(to: NSPoint(x: centreX + half / 2, y: centreY))
            path.line(to: NSPoint(x: centreX - half / 2, y: centreY + half))
        } else {
            path.move(to: NSPoint(x: centreX - half, y: centreY - half / 2))
            path.line(to: NSPoint(x: centreX, y: centreY + half / 2))
            path.line(to: NSPoint(x: centreX + half, y: centreY - half / 2))
        }

        path.lineWidth = 1.4
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        (collapsed ? NSColor.labelColor : NSColor.secondaryLabelColor).setStroke()
        path.stroke()
    }

    public override func drawHashMarksAndLabels(in rect: NSRect) {
        textView.backgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.maxX - 1, y: rect.minY, width: 1, height: rect.height).fill()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        for label in visibleLabels() {
            let text = NSAttributedString(string: String(label.number), attributes: attributes)
            let size = text.size()
            // Draw so that the text's baseline lands on the baseline of the line's first row.
            let top = isFlipped ? label.baseline - font.ascender : label.baseline - font.ascender
            let numberEdge = bounds.maxX - 8 - (showsFolding ? Self.foldColumnWidth : 0)
            text.draw(at: NSPoint(x: numberEdge - size.width, y: top))
            if let collapsed = foldMarks[label.number - 1], collapsed || isPointerInside {
                drawFoldArrow(collapsed: collapsed, centreY: top + size.height / 2)
            }

            if let severity = problemLines[label.number - 1] {
                Self.colour(for: severity).setFill()
                NSBezierPath(ovalIn: NSRect(
                    x: 4,
                    y: top + (size.height - Self.markerSize) / 2,
                    width: Self.markerSize,
                    height: Self.markerSize
                )).fill()
            }
        }
    }
}
