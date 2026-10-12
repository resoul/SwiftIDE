import AppKit
import IDEApplication

/// Package-owned review form; the host chooses its window and owns closing it.
@MainActor
public final class GitPushViewController: NSViewController, NSTextFieldDelegate {
    public let model: GitPushReview
    public var close: (() -> Void)?
    let branch = NSPopUpButton(frame: .zero, pullsDown: false)
    let remote = NSPopUpButton(frame: .zero, pullsDown: false)
    let destination = NSTextField(string: "")
    let review = NSButton(title: "Review Destination", target: nil, action: nil)
    let push = NSButton(title: "Push", target: nil, action: nil)
    let cancel = NSButton(title: "Close", target: nil, action: nil)
    private let details = NSTextField(wrappingLabelWithString: "")
    private let status = NSTextField(wrappingLabelWithString: "")
    private let output = NSTextView()
    private var branches: [GitBranch] = []
    private var subscription: UUID?

    public init(model: GitPushReview) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func loadView() {
        view = GitPushBackground(frame: NSRect(x: 0, y: 0, width: 660, height: 490))
        let title = NSTextField(labelWithString: "Push Branch")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        for control in [branch, remote] {
            control.target = self
            control.action = #selector(selectionChanged(_:))
        }
        branch.setAccessibilityLabel("Local source branch")
        remote.setAccessibilityLabel("Remote to push")
        destination.placeholderString = "Remote branch name"
        destination.setAccessibilityLabel("Destination branch name")
        destination.delegate = self
        review.target = self
        review.action = #selector(reviewDestination(_:))
        push.target = self
        push.action = #selector(pushReviewed(_:))
        cancel.target = self
        cancel.action = #selector(cancelPush(_:))
        cancel.keyEquivalent = "\u{1b}"
        // Return must not accidentally publish while editing the form.
        details.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        details.isSelectable = true
        details.maximumNumberOfLines = 6
        status.font = .systemFont(ofSize: 12)
        let note =
            NSTextField(
                wrappingLabelWithString: """
                Sends committed history reachable from the reviewed commit. Uncommitted changes are not sent. The \
                destination can be a new branch; an existing branch must accept a fast-forward. Upstream settings \
                stay unchanged.
                """
            )
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        output.isEditable = false
        output.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        output.setAccessibilityLabel("Push output")
        let scroll = NSScrollView.nonElastic()
        scroll.documentView = output
        scroll.hasVerticalScroller = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 90).isActive = true
        gitPin(gitStack([
            title,
            gitStack([branch, remote], vertical: false),
            destination,
            note,
            details,
            status,
            scroll,
            gitStack([cancel, review, push], vertical: false)
        ]), to: view, inset: 20)
        subscription = model.subscribe { [weak self] in self?.render() }
        render()
    }

    public func select(branch reference: String?, remote name: String?) {
        _ = view
        if let reference, let index = branches.firstIndex(where: { $0.reference == reference }) {
            branch.selectItem(at: index)
        }

        if let name, remote.itemTitles.contains(name) { remote.selectItem(withTitle: name) }
        let suggestion = selectedBranch?.trackingSuggestion(in: remote.itemTitles)
        if name == nil, let suggestion { remote.selectItem(withTitle: suggestion.remote) }
        destination.stringValue = suggestion?.remote == remote.titleOfSelectedItem
            ? suggestion?.branch ?? ""
            : selectedBranch?.name ?? ""
        model.invalidate()
    }

    private var selectedBranch: GitBranch? {
        branches.indices.contains(branch.indexOfSelectedItem) ? branches[branch.indexOfSelectedItem] : nil
    }

    @objc func selectionChanged(_ sender: Any?) {
        if sender as? NSPopUpButton === branch {
            let suggestion = selectedBranch?.trackingSuggestion(in: remote.itemTitles)
            if let suggestion { remote.selectItem(withTitle: suggestion.remote) }
            destination.stringValue = suggestion?.branch ?? selectedBranch?.name ?? ""
        }

        model.invalidate()
    }

    public func controlTextDidChange(_ notification: Notification) { model.invalidate() }

    @objc func reviewDestination(_ sender: Any?) {
        guard review.isEnabled, let branch = selectedBranch, let remote = remote.titleOfSelectedItem else { return }

        model.review(branch: branch, remote: remote, destination: destination.stringValue)
    }

    @objc func pushReviewed(_ sender: Any?) { if push.isEnabled { model.push() } }

    @objc func cancelPush(_ sender: Any?) {
        if model.workspace.operationState.isBusy { model.workspace.cancelOperation() } else { close?() }
    }

    private func render() {
        let workspace = model.workspace
        let old = selectedBranch?.reference
        branches = (workspace.snapshot?.branches ?? []).filter { !$0.isRemote }
        if branch.itemTitles != branches.map(\.name) {
            branch.removeAllItems()
            branch.addItems(withTitles: branches.map(\.name))
            let preferred = old ?? workspace.snapshot?.branch.map { "refs/heads/" + $0 }
            if let index = branches.firstIndex(where: { $0.reference == preferred }) { branch.selectItem(at: index) }
            if old == nil || !branches.contains(where: { $0.reference == old }) {
                destination.stringValue = selectedBranch?.name ?? ""
            }
        }

        let previousRemote = remote.titleOfSelectedItem, names = workspace.snapshot?.remotes ?? []
        if remote.itemTitles != names {
            remote.removeAllItems()
            remote.addItems(withTitles: names)
            if let previousRemote, names.contains(previousRemote) { remote.selectItem(withTitle: previousRemote) }
        }

        let busy = workspace.operationState.isBusy, reviewing = model.state == .loading
        branch.isEnabled = !busy
        remote.isEnabled = !busy
        destination.isEnabled = !busy
        review.isEnabled = workspace.canMutate && !reviewing && selectedBranch != nil && remote
            .titleOfSelectedItem != nil && !destination.stringValue.isEmpty
        push.isEnabled = model.canPush
        cancel.title = busy ? "Cancel Push" : "Close"
        cancel.isEnabled = workspace.operationState != .cancelling
        let shownPlan = model.plan ?? model.submittedPlan
        details.stringValue = shownPlan
            .map {
                "Source: " + $0.branch.name + " @ " + $0.branch.oid + "\nRemote: " + $0.remote + "\nAddress: " + $0
                    .url + "\nDestination: refs/heads/" + $0.destination
            } ?? "Review the destination before sending."
        if model.plan == nil, model.submittedPlan != nil {
            details.stringValue = "Last Push attempt\n" + details.stringValue
        }

        details.toolTip = details.stringValue
        status.stringValue = reviewing
            ? "Reading push configuration…"
            : (model.state == .ready ? "Ready for explicit Push" : model.state == .idle ? "" : model.state.explanation)
        if model.operationStarted, !workspace.operationTitle.isEmpty, model.state != .ready, !reviewing {
            status.stringValue += "\n" + workspace.operationTitle + " · " + workspace.operationState.explanation
        }

        let text = model.operationStarted ? workspace.operationOutput : ""
        if output.string != text {
            output.string = text
            output.scrollRangeToVisible(NSRange(location: (output.string as NSString).length, length: 0))
        }
    }

    public func disconnect() {
        if let subscription { model.unsubscribe(subscription) }
        subscription = nil
    }
}

@MainActor private final class GitPushBackground: NSView {
    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            dirtyRect.fill()
        }
    }
}
