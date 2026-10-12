import AppKit
import IDEApplication

/// Package-owned review form; the host chooses its window and owns closing it.
@MainActor
public final class GitPullViewController: NSViewController, NSTextFieldDelegate {
    public let model: GitPullReview
    public var close: (() -> Void)?
    private let branch = NSTextField(labelWithString: "")
    let remote = NSPopUpButton(frame: .zero, pullsDown: false)
    let source = NSTextField(string: "")
    let review = NSButton(title: "Review Source", target: nil, action: nil)
    let pull = NSButton(title: "Pull", target: nil, action: nil)
    let cancel = NSButton(title: "Close", target: nil, action: nil)
    private let details = NSTextField(wrappingLabelWithString: "")
    private let status = NSTextField(wrappingLabelWithString: "")
    private let output = NSTextView()
    private var subscription: UUID?

    public init(model: GitPullReview) { self.model = model; super.init(nibName: nil, bundle: nil) }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func loadView() {
        view = GitPullBackground(frame: NSRect(x: 0, y: 0, width: 660, height: 490))
        let title = NSTextField(labelWithString: "Pull Branch")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        remote.target = self; remote.action = #selector(selectionChanged(_:))
        branch.setAccessibilityLabel("Current local branch"); remote.setAccessibilityLabel("Remote to pull")
        source.placeholderString = "Remote branch name"
        source.setAccessibilityLabel("Source branch name")
        source.delegate = self
        review.target = self; review.action = #selector(reviewSource(_:))
        pull.target = self; pull.action = #selector(pullReviewed(_:))
        cancel.target = self; cancel.action = #selector(cancelPull(_:)); cancel.keyEquivalent = "\u{1b}"
        // Return must not accidentally update the checkout while editing the form.
        details.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        details.isSelectable = true
        details.maximumNumberOfLines = 6
        status.font = .systemFont(ofSize: 12)
        let note =
            NSTextField(
                wrappingLabelWithString: """
                Fetches one remote branch and fast-forwards the current local branch. Save or cancel open documents \
                first; tracked files and index must be clean. No merge, rebase or stash. Editors are temporarily \
                locked; upstream stays unchanged.
                """
            )
        note.font = .systemFont(ofSize: 11); note.textColor = .secondaryLabelColor
        output.isEditable = false
        output.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        output.setAccessibilityLabel("Pull output")
        let scroll = NSScrollView(); scroll.documentView = output; scroll.hasVerticalScroller = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 90).isActive = true
        gitPin(gitStack([
            title,
            gitStack([branch, remote], vertical: false),
            source,
            note,
            details,
            status,
            scroll,
            gitStack([cancel, review, pull], vertical: false)
        ]), to: view, inset: 20)
        subscription = model.subscribe { [weak self] in self?.render() }
        render()
    }
    public func select(remote name: String?, source value: String?) {
        _ = view
        let upstream = model.workspace.snapshot?.branches.first { $0.name == model.workspace.snapshot?.branch }?
            .upstream
        if let name, remote.itemTitles.contains(name) { remote.selectItem(withTitle: name) }
        else if name == nil, let upstream,
                let trackingRemote = remote.itemTitles.sorted(by: { $0.count > $1.count })
                .first(where: { upstream.hasPrefix("refs/remotes/" + $0 + "/") }) {
            remote.selectItem(withTitle: trackingRemote)
        }

        let prefix = "refs/remotes/" + (remote.titleOfSelectedItem ?? "") + "/"
        if let value { source.stringValue = value }
        else if let upstream, upstream.hasPrefix(prefix) {
            source.stringValue = String(upstream.dropFirst(prefix.count))
        }
        else { source.stringValue = model.workspace.snapshot?.branch ?? "" }

        model.invalidate()
    }

    @objc func selectionChanged(_ sender: Any?) { model.invalidate() }
    public func controlTextDidChange(_ notification: Notification) { model.invalidate() }
    @objc func reviewSource(_ sender: Any?) {
        guard review.isEnabled, let remote = remote.titleOfSelectedItem else { return }

        model.review(remote: remote, source: source.stringValue)
    }
    @objc func pullReviewed(_ sender: Any?) { if pull.isEnabled { model.pull() } }
    @objc func cancelPull(_ sender: Any?) {
        if model.workspace.operationState.isBusy { model.workspace.cancelOperation() } else { close?() }
    }
    private func render() {
        let workspace = model.workspace
        branch.stringValue = "Current branch: " + (workspace.snapshot?.headDescription ?? "unavailable")
        let previousRemote = remote.titleOfSelectedItem, names = workspace.snapshot?.remotes ?? []
        if remote.itemTitles != names {
            remote.removeAllItems(); remote.addItems(withTitles: names)
            if let previousRemote, names.contains(previousRemote) { remote.selectItem(withTitle: previousRemote) }
        }

        let busy = workspace.operationState.isBusy, reviewing = model.state == .loading
        remote.isEnabled = !busy; source.isEnabled = !busy
        review.isEnabled = workspace.canMutate && !reviewing && workspace.snapshot?.branch != nil && workspace.snapshot?
            .head != nil && remote.titleOfSelectedItem != nil && !source.stringValue.isEmpty
        pull.isEnabled = model.canPull
        cancel.title = busy ? "Cancel Pull" : "Close"; cancel.isEnabled = workspace.operationState != .cancelling
        let shownPlan = model.plan ?? model.submittedPlan
        details.stringValue = shownPlan
            .map {
            "Local: " + $0.branch.name + " @ " + $0.branch.oid + "\nRemote: " + $0.remote + "\nAddress: " + $0
            .url + "\nRemote source: refs/heads/" + $0.source } ?? "Review the source before updating the checkout."
        if model.plan == nil, model.submittedPlan != nil {
            details.stringValue = "Last Pull attempt\n" + details.stringValue
        }

        details.toolTip = details.stringValue
        status.stringValue = reviewing
            ? "Reading pull configuration…"
            : (model.state == .ready ? "Ready for explicit Pull" : model.state == .idle ? "" : model.state.explanation)
        if model.operationStarted, !workspace.operationTitle.isEmpty, model.state != .ready, !reviewing {
            status.stringValue += "\n" + workspace.operationTitle + " · " + workspace.operationState.explanation
        }

        let text = model.operationStarted ? workspace.operationOutput : ""
        if output.string != text {
            output.string = text
            output.scrollRangeToVisible(NSRange(location: (output.string as NSString).length, length: 0))
        }
    }
    public func disconnect() { if let subscription { model.unsubscribe(subscription) }; subscription = nil }
}

@MainActor private final class GitPullBackground: NSView {
    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            dirtyRect.fill()
        }
    }
}
