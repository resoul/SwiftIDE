import AppKit
import IDEApplication

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

    // MARK: Width

    private func updateThickness() {
        let digits = max(3, String(lineIndex.index.lineCount).count)
        let digitWidth = ("0" as NSString).size(withAttributes: [.font: font]).width
        let wanted = ceil(CGFloat(digits) * digitWidth) + 16
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

    public override func drawHashMarksAndLabels(in rect: NSRect) {
        NSColor.textBackgroundColor.setFill()
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
            text.draw(at: NSPoint(x: bounds.maxX - 8 - size.width, y: top))
        }
    }
}
