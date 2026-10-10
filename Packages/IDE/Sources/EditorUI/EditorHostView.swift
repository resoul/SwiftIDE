import AppKit
import EditorPlatformTextKit
import IDEApplication

/// Scrollable container for one TextKit 2 text view. Owns geometry only, not text.
@MainActor
public final class EditorHostView: NSScrollView {
    public let textView: NSTextView

    /// `lineIndex` adds a line-number margin.
    public init(editor: TextKitEditor, lineIndex: DocumentLineIndex? = nil) {
        textView = editor.textView
        super.init(frame: .zero)
        hasVerticalScroller = true
        hasHorizontalScroller = false
        drawsBackground = true
        borderType = .noBorder
        documentView = textView
        if let lineIndex {
            verticalRulerView = LineNumberRulerView(scrollView: self, textView: textView, lineIndex: lineIndex)
            hasVerticalRuler = true
            rulersVisible = true
        }
    }

    /// The line-number margin, if the view has one.
    public var lineNumberRuler: LineNumberRulerView? { verticalRulerView as? LineNumberRulerView }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
