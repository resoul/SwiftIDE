import AppKit
import EditorPlatformTextKit

/// Scrollable container for one TextKit 2 text view. Owns geometry only, not text.
@MainActor
public final class EditorHostView: NSScrollView {
    public let textView: NSTextView

    public init(editor: TextKitEditor) {
        textView = editor.textView
        super.init(frame: .zero)
        hasVerticalScroller = true
        hasHorizontalScroller = false
        drawsBackground = true
        borderType = .noBorder
        documentView = textView
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
