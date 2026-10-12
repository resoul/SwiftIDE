import AppKit
import IDEApplication

@MainActor
public final class GitStashViewController: NSViewController, NSTextFieldDelegate {
    public let model: GitStashes
    public var start: ((GitStashPlan) -> Void)?
    public var preview: ((GitStashEntry) -> Void)?
    public var close: (() -> Void)?
    let list = GitListView(label: "Saved Git stashes")
    let mode = NSPopUpButton(frame: .zero, pullsDown: false)
    let inclusion = NSPopUpButton(frame: .zero, pullsDown: false)
    let message = NSTextField(string: "")
    let restoreIndex = NSButton(checkboxWithTitle: "Restore staged changes (--index)", target: nil, action: nil)
    let review = NSButton(title: "Review", target: nil, action: nil)
    let apply = NSButton(title: "Create stash", target: nil, action: nil)
    let inspect = NSButton(title: "View diff", target: nil, action: nil)
    let details = NSTextField(wrappingLabelWithString: "")
    private var subscription: UUID?
    private var selected: GitStashEntry? {
        model.list?.entries.first { $0.key == list.selectedKey }
    }

    public init(workspace: GitWorkspace) {
        model = GitStashes(workspace: workspace)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func loadView() {
        view = GitContextBackground(frame: NSRect(x: 0, y: 0, width: 720, height: 650))
        let title = NSTextField(labelWithString: "Stashes")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        let refresh = NSButton(title: "Refresh", target: self, action: #selector(refreshList(_:)))
        mode.addItems(withTitles: [
            "Create stash",
            "Apply and keep",
            "Pop after successful apply",
            "Drop without applying"
        ])
        inclusion.addItems(withTitles: GitStashInclusion.allCases.map(\.rawValue))
        mode.setAccessibilityLabel("Stash operation")
        inclusion.setAccessibilityLabel("Files to stash")
        message.placeholderString = "Optional stash message"
        message.setAccessibilityLabel("Stash message")
        message.delegate = self
        for control in [mode, inclusion] {
            control.target = self
            control.action = #selector(selectionChanged(_:))
        }
        restoreIndex.target = self
        restoreIndex.action = #selector(selectionChanged(_:))
        review.target = self
        review.action = #selector(reviewSelection(_:))
        apply.target = self
        apply.action = #selector(applyReviewed(_:))
        inspect.target = self
        inspect.action = #selector(inspectSelection(_:))
        details.isSelectable = true
        details.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        details.maximumNumberOfLines = 7
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(closeForm(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let note = NSTextField(wrappingLabelWithString: """
        Create saves the current disk changes and cleans those files. Open unsaved documents require Save or Cancel. \
        Apply/Pop requires clean tracked files; conflicts retain the stash. Drop removes the saved entry. \
        Cancelling does not roll back changes already made.
        """)
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        list.heightAnchor.constraint(greaterThanOrEqualToConstant: 170).isActive = true
        gitPin(gitStack([
            gitStack([title, NSView(), refresh], vertical: false),
            list,
            inspect,
            mode,
            inclusion,
            message,
            restoreIndex,
            note,
            details,
            gitStack([cancel, review, apply], vertical: false)
        ]), to: view, inset: 16)
        list.onSelect = { [weak self] _ in self?.model.invalidate() }
        list.onOpen = { [weak self] _ in self?.inspectSelection(nil) }
        subscription = model.subscribe { [weak self] in self?.render() }
        render()
    }

    @objc func selectionChanged(_ sender: Any?) { model.invalidate() }

    public func controlTextDidChange(_ notification: Notification) { model.invalidate() }

    @objc func refreshList(_ sender: Any?) { model.workspace.refresh() }

    @objc func inspectSelection(_ sender: Any?) {
        guard model.canInspect, let selected else { return }

        preview?(selected)
    }

    @objc func reviewSelection(_ sender: Any?) {
        guard review.isEnabled else { return }

        switch mode.indexOfSelectedItem {
        case 0:
            guard GitStashInclusion.allCases.indices.contains(inclusion.indexOfSelectedItem) else { return }

            model.review(.create(
                message: message.stringValue,
                inclusion: GitStashInclusion.allCases[inclusion.indexOfSelectedItem]
            ))
        case 1:
            if let selected { model.review(.apply(selected, restoreIndex: restoreIndex.state == .on)) }
        case 2:
            if let selected { model.review(.pop(selected, restoreIndex: restoreIndex.state == .on)) }
        case 3:
            if let selected { model.review(.drop(selected)) }
        default: break
        }
    }

    @objc func applyReviewed(_ sender: Any?) {
        if model.canStart, let plan = model.plan { start?(plan) }
    }

    @objc private func closeForm(_ sender: Any?) { close?() }

    private func render() {
        list.present((model.list?.entries ?? []).map {
            GitListRow(
                key: $0.key,
                title: $0.selector + " · " + $0.message,
                detail: String($0.oid.prefix(12)) + " · " + $0.date.formatted()
            )
        })
        let create = mode.indexOfSelectedItem == 0
        inclusion.isHidden = !create
        message.isHidden = !create
        restoreIndex.isHidden = create || mode.indexOfSelectedItem == 3
        let busy = model.workspace.operationState.isBusy
        mode.isEnabled = !busy
        inclusion.isEnabled = !busy
        message.isEnabled = !busy
        restoreIndex.isEnabled = !busy
        review.isEnabled = model.canReview && (create || selected != nil)
        apply.isEnabled = model.canStart
        inspect.isEnabled = selected != nil && model.canInspect
        apply.title = ["Create stash", "Apply stash", "Pop stash", "Drop stash"][max(0, mode.indexOfSelectedItem)]
        if let plan = model.plan {
            var text = "Repository: " + plan.repository.root + "\n" + plan.request.title
            if let entry = plan.request.entry {
                text += "\n" + entry.selector + " @ " + entry.oid + "\n" + entry.message
            }

            switch plan.request {
            case .create(_, let inclusion):
                text += "\n" + inclusion.rawValue + "; captures ALL eligible saved changes at execution."
            case .apply(_, let restore), .pop(_, let restore):
                text += restore
                    ? "\nRestore the saved index as well as files."
                    : "\nApply to files; keep index unstaged."
            case .drop:
                text += "\nDeletes this saved entry without applying its changes."
            }
            details.stringValue = text
        } else if let error = model.reviewError {
            details.stringValue = error
        } else {
            let count = model.list?.entries.count ?? 0
            details.stringValue = model.state == .ready
                ? "\(count) stashes" + (model.list?.hasMore == true ? " · showing the newest 200" : "")
                    + ". Choose an operation and Review."
                : model.state.explanation
        }

        details.toolTip = details.stringValue
    }

    public func disconnect() {
        if let subscription { model.unsubscribe(subscription) }
        subscription = nil
        model.stop()
    }
}
