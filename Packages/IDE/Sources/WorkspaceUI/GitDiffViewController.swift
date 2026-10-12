import AppKit
import IDEApplication

@MainActor
public final class GitDiffViewController: NSViewController, NSTextViewDelegate {
    public let model: GitWorkspace
    public let text = NSTextView(usingTextLayoutManager: true)
    public let hunk = NSPopUpButton()
    public let applyHunk = NSButton(title: "Stage block", target: nil, action: nil)
    public let applyLines = NSButton(title: "Stage selected lines", target: nil, action: nil)
    private let heading = NSTextField(wrappingLabelWithString: "")
    private let notice = NSTextField(wrappingLabelWithString: "")
    private var actionBar: NSStackView?
    private var operation: GitOperationView?
    private var presentedToken: String?
    private var subscription: UUID?
    private var presentedText: String?

    public init(model: GitWorkspace) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func loadView() {
        view = GitContextBackground(frame: NSRect(x: 0, y: 0, width: 720, height: 520))
        text.isEditable = false
        text.delegate = self
        text.isRichText = false
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.setAccessibilityLabel("Read-only Git diff")
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        let scroll = NSScrollView.nonElastic()
        scroll.hasVerticalScroller = true
        scroll.documentView = text
        heading.font = .systemFont(ofSize: 12)
        heading.setContentHuggingPriority(.required, for: .vertical)
        hunk.setAccessibilityLabel("Diff block")
        hunk.target = self
        hunk.action = #selector(selectHunk(_:))
        applyHunk.target = self
        applyHunk.action = #selector(stageHunk(_:))
        applyLines.target = self
        applyLines.action = #selector(stageLines(_:))
        let bar = gitStack([hunk, applyHunk, applyLines], vertical: false)
        actionBar = bar
        notice.font = .systemFont(ofSize: 11)
        notice.textColor = .secondaryLabelColor
        notice.maximumNumberOfLines = 3
        let operation = GitOperationView(model: model)
        self.operation = operation
        gitPin(gitStack([heading, bar, notice, scroll, operation]), to: view, inset: 10)
        subscription = model.subscribe { [weak self] in self?.render() }
        render()
    }

    private func render() {
        heading.stringValue = (model.comparison?.title ?? "Git diff") + " · " + model.diffState.explanation
        if let partial = model.partialDiff, presentedToken != partial.token {
            presentedToken = partial.token
            hunk.removeAllItems()
            hunk.addItems(withTitles: partial.hunks.map(\.header))
            text.setSelectedRange(NSRange(location: 0, length: 0))
        }

        if model.partialDiff == nil, model.diffState != .loading {
            presentedToken = nil
            hunk.removeAllItems()
        }

        notice.stringValue = model.partialDiff == nil
            ? model.partialDiffNotice
            : "Only saved disk/index changes are used. Unsaved editor text is not staged."
        notice.isHidden = notice.stringValue.isEmpty
        actionBar?.isHidden = model.partialDiff == nil && presentedToken == nil
        updateActions()
        operation?.render()
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
        updateActions()
    }

    private var selectedLines: Set<Int> {
        guard let diff = model.partialDiff, text.selectedRange().length > 0 else { return [] }

        let range = text.selectedRange()

        return Set(diff.hunks.flatMap(\.lines).filter {
            $0.kind != .context && NSIntersectionRange(
                range,
                NSRange(location: $0.range.location, length: $0.range.length)
            )
            .length > 0
        }.map(\.id))
    }

    private func updateActions() {
        let ready = model.canMutate && model.diffState == .ready && model.partialDiff != nil
        let verb = model.partialDiff?.isUnstage == true ? "Unstage" : "Stage"
        applyHunk.title = verb + " block"
        applyLines.title = verb + " selected lines"
        applyHunk.isEnabled = ready && hunk.indexOfSelectedItem >= 0
        applyLines.isEnabled = ready && !selectedLines.isEmpty
        hunk.isEnabled = ready
    }

    public func textViewDidChangeSelection(_ notification: Notification) { updateActions() }

    @objc public func selectHunk(_ sender: Any?) {
        guard let diff = model.partialDiff, diff.hunks.indices.contains(hunk.indexOfSelectedItem),
              let line = diff.hunks[hunk.indexOfSelectedItem].lines.first else { return }

        text.scrollRangeToVisible(NSRange(location: line.range.location, length: line.range.length))
    }

    @objc public func stageHunk(_ sender: Any?) {
        guard applyHunk.isEnabled, let diff = model.partialDiff,
              diff.hunks.indices.contains(hunk.indexOfSelectedItem) else {
            return
        }

        model.perform(.partial(.init(diff: diff, lines: diff.hunks[hunk.indexOfSelectedItem].changedIDs)))
    }

    @objc public func stageLines(_ sender: Any?) {
        guard applyLines.isEnabled, let diff = model.partialDiff else { return }

        model.perform(.partial(.init(diff: diff, lines: selectedLines)))
    }

    public func disconnect() {
        if let subscription { model.unsubscribe(subscription) }
        subscription = nil
    }
}
