import AppKit
import IDEApplication
import IDEDomain

/// Draws a document's problems under the text: a wavy line, red for an error, yellow for a warning,
/// grey for the rest. A report that names no version is drawn paler than one that does, and every
/// mark is paler still once the text has changed since the report arrived.
///
/// TextKit 2's rendering attributes do not draw underlines (checked on this system), so the lines
/// are drawn by a transparent view laid over the text view. It takes no clicks, keeps no text and
/// touches nothing of the document, its revisions or its undo history.
@MainActor
public final class DiagnosticsPresenter: DiagnosticsPresenting {
    private let overlay: DiagnosticsOverlayView

    public init(textView: NSTextView) {
        overlay = DiagnosticsOverlayView(textView: textView)
        overlay.frame = textView.bounds
        overlay.autoresizingMask = [.width, .height]
        textView.addSubview(overlay)
    }

    isolated deinit {
        overlay.removeFromSuperview()
    }

    public func show(_ marks: [DiagnosticMark]) {
        overlay.marks = marks
    }

    /// An empty range is drawn under the character after it, or the one before at the end.
    static func visibleRange(of range: UTF16TextRange, documentLength: Int) -> UTF16TextRange? {
        guard documentLength > 0, range.location <= documentLength else { return nil }

        let start = min(range.location, documentLength - (range.length == 0 ? 1 : 0))
        let end = min(documentLength, start + max(1, range.length))

        return start < end ? UTF16TextRange(location: start, length: end - start) : nil
    }

    static func colour(for mark: DiagnosticMark) -> NSColor {
        let base: NSColor = switch mark.severity {
        case .error: .systemRed
        case .warning: .systemYellow
        case .information, .hint: .systemGray
        }

        switch mark.freshness {
        case .verified: return base
        case .unverified: return base.withAlphaComponent(0.7)
        case .stale: return base.withAlphaComponent(0.4)
        }
    }
}

final class DiagnosticsOverlayView: NSView {
    private weak var textView: NSTextView?
    var marks: [DiagnosticMark] = [] {
        didSet { if marks != oldValue { needsDisplay = true } }
    }

    init(textView: NSTextView) {
        self.textView = textView
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { textView?.isFlipped ?? true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard !marks.isEmpty, let textView, let manager = textView.textLayoutManager,
              let content = manager.textContentManager else { return }

        let origin = textView.textContainerOrigin
        let length = content.offset(from: content.documentRange.location, to: content.documentRange.endLocation)
        // The worst last, so that it is on top.
        for mark in marks.sorted(by: { $0.severity > $1.severity }) {
            guard let range = DiagnosticsPresenter.visibleRange(of: mark.range, documentLength: length),
                  let from = content.location(content.documentRange.location, offsetBy: range.location),
                  let to = content.location(from, offsetBy: range.length),
                  let textRange = NSTextRange(location: from, end: to) else { continue }

            let colour = DiagnosticsPresenter.colour(for: mark)
            manager.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, frame, _, _ in
                let rect = frame.offsetBy(dx: origin.x, dy: origin.y)
                if rect.intersects(dirtyRect) { Self.squiggle(under: rect, colour: colour) }

                return true
            }
        }
    }

    /// A wavy line along the bottom of the rectangle.
    static func squiggle(under rect: NSRect, colour: NSColor) {
        let path = NSBezierPath()
        let baseline = rect.maxY - 1.5
        let step: CGFloat = 2
        var x = rect.minX
        var up = true
        path.move(to: NSPoint(x: x, y: baseline))
        while x < rect.maxX {
            x = min(rect.maxX, x + step)
            path.line(to: NSPoint(x: x, y: baseline + (up ? -1.5 : 0)))
            up.toggle()
        }
        path.lineWidth = 1
        colour.setStroke()
        path.stroke()
    }
}
