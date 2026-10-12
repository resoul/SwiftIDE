import AppKit
import IDEApplication

@MainActor
public final class GitDiffViewController: NSViewController {
    public let model: GitWorkspace
    public let text = NSTextView(usingTextLayoutManager: true)
    private let heading = NSTextField(wrappingLabelWithString: "")
    private var subscription: UUID?
    private var presentedText: String?

    public init(model: GitWorkspace) { self.model = model; super.init(nibName: nil, bundle: nil) }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func loadView() {
        view = NSView()
        text.isEditable = false; text.isRichText = false
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.setAccessibilityLabel("Read-only Git diff")
        text.isVerticallyResizable = true; text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        let scroll = NSScrollView.nonElastic(); scroll.hasVerticalScroller = true; scroll.documentView = text
        heading.font = .systemFont(ofSize: 12); heading.setContentHuggingPriority(.required, for: .vertical)
        gitPin(gitStack([heading, scroll]), to: view, inset: 10)
        subscription = model.subscribe { [weak self] in self?.render() }
        render()
    }
    private func render() {
        heading.stringValue = (model.comparison?.title ?? "Git diff") + " · " + model.diffState.explanation
        guard presentedText != model.diffText else { return }

        presentedText = model.diffText
        let value = NSMutableAttributedString(
            string: model.diffText,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: NSColor.labelColor
            ]
        )
        let ns = model.diffText as NSString
        var position = 0
        while position < ns.length {
            let range = ns.lineRange(for: NSRange(location: position, length: 0))
            let line = ns.substring(with: range)
            let colour: NSColor? = line.hasPrefix("+")
                ? .systemGreen
                : line.hasPrefix("-") ? .systemRed : line.hasPrefix("@@") ? .systemBlue : nil
            if let colour { value.addAttribute(.foregroundColor, value: colour, range: range) }
            position = NSMaxRange(range)
        }
        text.textStorage?.setAttributedString(value)
        text.setSelectedRange(NSRange(location: 0, length: 0))
        text.scrollRangeToVisible(NSRange(location: 0, length: 0))
    }
    public func disconnect() { if let subscription { model.unsubscribe(subscription) }; subscription = nil }
}
