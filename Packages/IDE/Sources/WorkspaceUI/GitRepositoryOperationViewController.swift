import AppKit
import IDEApplication

@MainActor
public final class GitRepositoryOperationViewController: NSViewController, NSTextFieldDelegate {
    public let model: GitRepositoryOperationReview
    public var start: ((GitRepositoryOperationPlan) -> Void)?
    public var close: (() -> Void)?
    private let kind = NSPopUpButton()
    private let value = NSTextField(string: "")
    let address = NSTextField(string: "")
    private let mainline = NSTextField(string: "0")
    private let tags = NSButton(
        checkboxWithTitle: "Also fetch tags (never prune/overwrite local tags)",
        target: nil,
        action: nil
    )
    private let prune = NSButton(
        checkboxWithTitle: "Prune missing branches in this remote namespace",
        target: nil,
        action: nil
    )
    let reviewButton = NSButton(title: "Review", target: nil, action: nil)
    private let apply = NSButton(title: "Apply reviewed operation…", target: nil, action: nil)
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let guidance = NSTextField(wrappingLabelWithString: "")
    private var subscription: UUID?
    private var selectedKind: GitRepositoryOperationKind {
        GitRepositoryOperationKind.allCases[kind.indexOfSelectedItem]
    }

    public init(model: GitRepositoryOperationReview) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func loadView() {
        view = GitContextBackground(frame: NSRect(x: 0, y: 0, width: 720, height: 440))
        let title = NSTextField(labelWithString: "Repository Operations")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        kind.addItems(withTitles: GitRepositoryOperationKind.allCases.map(\.rawValue))
        for control in [kind, tags, prune] as [NSControl] {
            control.target = self
            control.action = #selector(inputsChanged(_:))
        }
        kind.setAccessibilityLabel("Repository operation")
        address.delegate = self
        address.placeholderString = "Submodule repository URL"
        address.setAccessibilityLabel("Submodule repository URL")
        value.delegate = self
        value.setAccessibilityLabel("Exact revision, file path, remote name or submodule path")
        mainline.delegate = self
        mainline.setAccessibilityLabel("Mainline parent: 0 for linear commits, 1 or higher for merge commits")
        reviewButton.target = self
        reviewButton.action = #selector(reviewOperation(_:))
        apply.target = self
        apply.action = #selector(startReviewed(_:))
        let cancel = NSButton(title: "Close", target: self, action: #selector(closeForm(_:)))
        cancel.keyEquivalent = "\u{1b}"
        guidance.font = .systemFont(ofSize: 11)
        detail.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        detail.isSelectable = true
        let operation = GitOperationView(model: model.workspace)
        gitPin(gitStack([
            title,
            kind,
            guidance,
            value,
            address,
            mainline,
            tags,
            prune,
            detail,
            operation,
            gitStack([cancel, reviewButton, apply], vertical: false)
        ]), to: view, inset: 16)
        subscription = model.subscribe { [weak self] in self?.render() }
        render()
    }

    public func select(_ selected: GitRepositoryOperationKind, value text: String = "") {
        _ = view
        kind.selectItem(at: GitRepositoryOperationKind.allCases.firstIndex(of: selected) ?? 0)
        value.stringValue = text
        model.invalidate()
    }

    public func controlTextDidChange(_ notification: Notification) { model.invalidate() }

    @objc private func inputsChanged(_ sender: Any?) { model.invalidate() }

    @objc private func reviewOperation(_ sender: Any?) {
        guard reviewButton.isEnabled, let parent = Int(mainline.stringValue) else { return }

        model.review(.init(
            kind: selectedKind,
            value: value.stringValue,
            mainline: parent,
            tags: selectedKind == .fetch && tags.state == .on,
            prune: selectedKind == .fetch && prune.state == .on,
            url: selectedKind == .addSubmodule ? address.stringValue : ""
        ))
    }

    @objc private func startReviewed(_ sender: Any?) {
        if model.canApply, let plan = model.plan { start?(plan) }
    }

    @objc private func closeForm(_ sender: Any?) { close?() }

    private func render() {
        let selected = selectedKind
        mainline.isHidden = selected != .cherryPick && selected != .revert
        tags.isHidden = selected != .fetch
        prune.isHidden = selected != .fetch
        address.isHidden = selected != .addSubmodule
        let path = selected == .discard || selected.isSubmodule
        value.placeholderString = selected == .addSubmodule
            ? "New submodule path, relative to the repository root"
            : path
                ? "Exact repository-relative path"
                : selected == .fetch ? "Remote name (e.g. origin)" : "Commit or reference"
        guidance.stringValue = selected == .addSubmodule
            ? """
            Review reads the remote HEAD of the URL below. Apply clones into the new path, stages .gitmodules \
            and the gitlink and reports a HEAD that moved after review; nothing is committed.
            """
            : path
                ? "Use a path relative to the repository root. Only the explicit reviewed path is affected."
                : selected == .fetch
                    ? """
                    Review reads the remote heads. Local branches stay unchanged; tags and pruning are separate \
                    explicit options.
                    """
                    : """
                    Review freezes the commit ID. Replay of a merge commit requires its mainline parent (1-based); \
                    ordinary commits use 0.
                    """
        reviewButton.isEnabled = model.workspace.canMutate && model.state != .loading && !value.stringValue.isEmpty
            && (selected != .addSubmodule || !address.stringValue.isEmpty)
        apply.isEnabled = model.canApply
        for control in [kind, value, address, mainline, tags, prune] as [NSControl] {
            control.isEnabled = !model.workspace.operationState.isBusy
        }
        detail.stringValue = model.plan?.summary ?? model.state.explanation
    }

    public func disconnect() {
        if let subscription { model.unsubscribe(subscription) }
        subscription = nil
        model.stop()
    }
}
