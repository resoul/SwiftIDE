import AppKit
import UITheme

@MainActor
final class ChatTextView: NSTextView {
    private let content = NSTextContentStorage()
    private var presentedValue: String?
    private var presentedMonospaced = false

    init(editable: Bool = false) {
        let layout = NSTextLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 300, height: CGFloat.greatestFiniteMagnitude))
        content.addTextLayoutManager(layout)
        layout.textContainer = container
        super.init(frame: .zero, textContainer: container)
        isEditable = editable
        isSelectable = true
        isRichText = false
        drawsBackground = false
        isVerticallyResizable = true
        isHorizontallyResizable = false
        textContainerInset = .zero
        textContainer?.lineFragmentPadding = 0
        textContainer?.widthTracksTextView = true
        textContainer?.heightTracksTextView = false
        font = .systemFont(ofSize: 13)
        textColor = .labelColor
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        allowsUndo = editable
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Message text is display-only: restoring a selection must never scroll the history table.
    override func scrollRangeToVisible(_ range: NSRange) {}

    /// Change only the differing suffix. Existing native selection and the text view survive deltas.
    func present(_ value: String, monospaced: Bool = false) {
        guard presentedValue != value || presentedMonospaced != monospaced else { return }

        presentedValue = value
        presentedMonospaced = monospaced
        let old = string as NSString, new = value as NSString
        let selection = selectedRange()
        var prefix = 0
        while prefix < min(old.length, new.length), old.character(at: prefix) == new.character(at: prefix) {
            prefix += 1
        }
        if prefix > 0, prefix < new.length,
           (0xD800...0xDBFF).contains(new.character(at: prefix - 1)),
           (0xDC00...0xDFFF).contains(new.character(at: prefix)) { prefix -= 1 }

        if old != new {
            textStorage?.replaceCharacters(
                in: NSRange(location: prefix, length: old.length - prefix),
                with: new.substring(from: prefix)
            )
        }

        let range = NSRange(location: 0, length: new.length)
        textStorage?.setAttributes(Self.attributes(monospaced: monospaced), range: range)
        let start = min(selection.location, new.length)
        setSelectedRange(NSRange(location: start, length: min(selection.length, new.length - start)))
    }

    static func attributes(monospaced: Bool = false) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        paragraph.lineBreakMode = .byWordWrapping

        return [
            .font: monospaced
                ? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
                : NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph
        ]
    }

    static func height(_ text: String, width: CGFloat, monospaced: Bool = false) -> CGFloat {
        let value = NSAttributedString(
            string: text.isEmpty ? " " : text,
            attributes: attributes(monospaced: monospaced)
        )
        let rect = value.boundingRect(
            with: NSSize(width: max(1, width), height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )

        return max(20, ceil(rect.height) + 5)
    }
}

@MainActor
final class ChatComposerTextView: NSTextView {
    private let content = NSTextContentStorage()
    var submit: (() -> Void)?
    var compositionChanged: (() -> Void)?

    init() {
        let layout = NSTextLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 300, height: CGFloat.greatestFiniteMagnitude))
        content.addTextLayoutManager(layout)
        layout.textContainer = container
        super.init(frame: .zero, textContainer: container)
        isRichText = false
        allowsUndo = true
        font = .systemFont(ofSize: 13)
        textColor = .labelColor
        backgroundColor = WorkspaceTheme.background
        isVerticallyResizable = true
        textContainerInset = NSSize(width: 8, height: 8)
        textContainer?.lineFragmentPadding = 0
        textContainer?.widthTracksTextView = true
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        setAccessibilityLabel("Message to the agent")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.shift, .command, .control, .option])
        if (event.keyCode == 36 || event.keyCode == 76), modifiers.isEmpty, !hasMarkedText() {
            submit?()

            return
        }

        super.keyDown(with: event)
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        compositionChanged?()
    }

    override func unmarkText() {
        super.unmarkText()
        compositionChanged?()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty, !hasMarkedText() {
            NSAttributedString(string: "Ask about your code…", attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.placeholderTextColor
            ]).draw(at: NSPoint(x: 8, y: 8))
        }
    }
}

@MainActor
class ChatSurface: NSView {
    var fillColor: NSColor = .clear { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
        needsLayout = true
    }

    override func draw(_ dirtyRect: NSRect) {
        fillColor.setFill()
        NSBezierPath(rect: dirtyRect).fill()
    }
}

@MainActor
func chatPin(_ child: NSView, to parent: NSView, inset: CGFloat = 0) {
    child.translatesAutoresizingMaskIntoConstraints = false
    parent.addSubview(child)
    NSLayoutConstraint.activate([
        child.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: inset),
        child.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -inset),
        child.topAnchor.constraint(equalTo: parent.topAnchor, constant: inset),
        child.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -inset)
    ])
}
