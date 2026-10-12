import AppKit
import IDEApplication

@MainActor
public final class GitManagementViewController: NSViewController, NSTextFieldDelegate {
    public let review: GitManagementReview
    public var start: ((GitManagementPlan) -> Void)?
    public var close: (() -> Void)?
    public let kind = NSPopUpButton()
    public let name = NSTextField(string: "")
    public let value = NSTextField(string: "")
    public let message = NSTextField(string: "")
    public let allowUnmerged = NSButton(
        checkboxWithTitle: "Allow deleting unmerged branch history",
        target: nil,
        action: nil
    )
    public let reviewButton = NSButton(title: "Review", target: nil, action: nil)
    public let apply = NSButton(title: "Apply reviewed action", target: nil, action: nil)
    private let summary = NSTextField(wrappingLabelWithString: "")
    private let nameLabel = NSTextField(labelWithString: "")
    private let valueLabel = NSTextField(labelWithString: "")
    private var subscription: UUID?

    public init(workspace: GitWorkspace) {
        review = .init(workspace: workspace)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func loadView() {
        view = GitContextBackground(frame: NSRect(x: 0, y: 0, width: 730, height: 600))
        kind.addItems(withTitles: GitManagementKind.allCases.map(\.rawValue))
        kind.target = self
        kind.action = #selector(kindChanged(_:))
        kind.setAccessibilityLabel("Repository action")
        for field in [name, value, message] { field.delegate = self }
        allowUnmerged.target = self
        allowUnmerged.action = #selector(inputChanged(_:))
        reviewButton.target = self
        reviewButton.action = #selector(reviewAction(_:))
        apply.target = self
        apply.action = #selector(applyAction(_:))
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        summary.font = .systemFont(ofSize: 12)
        summary.maximumNumberOfLines = 12
        let note =
            NSTextField(
                wrappingLabelWithString: """
                Local actions keep working files/index unchanged. Remote deletion is a separate network action; \
                Review shows its address and object.
                """
            )
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        gitPin(gitStack([
            kind,
            nameLabel,
            name,
            valueLabel,
            value,
            message,
            allowUnmerged,
            note,
            summary,
            gitStack([cancel, reviewButton, apply], vertical: false)
        ]), to: view, inset: 16)
        subscription = review.subscribe { [weak self] in self?.render() }
        kindChanged(nil)
    }

    private var selectedKind: GitManagementKind { GitManagementKind.allCases[max(0, kind.indexOfSelectedItem)] }

    @objc private func kindChanged(_ sender: Any?) {
        review.invalidate()
        let operation = selectedKind
        let remote = [.addRemote, .editRemote, .removeRemote, .deleteRemoteBranch, .deleteRemoteTag].contains(operation)
        nameLabel.stringValue = remote
            ? "Remote name"
            : [.createTag, .deleteTag].contains(operation) ? "Tag name" : "Local branch name"
        name.setAccessibilityLabel(nameLabel.stringValue)
        valueLabel.stringValue = operation == .renameBranch
            ? "New branch name"
            : operation == .createTag
                ? "Target commit (full hash; empty uses reviewed HEAD)"
                : operation.isNetwork ? "Remote branch/tag name (without refs prefix)" : "Repository URL"
        value.setAccessibilityLabel(valueLabel.stringValue)
        let needsValue = [.renameBranch, .createTag, .addRemote, .editRemote, .deleteRemoteBranch, .deleteRemoteTag]
            .contains(operation)
        valueLabel.isHidden = !needsValue
        value.isHidden = !needsValue
        allowUnmerged.isHidden = operation != .deleteBranch
        message.isHidden = operation != .createTag
        message.placeholderString = "Optional annotation (empty creates a lightweight tag)"
        message.setAccessibilityLabel("Tag annotation")
        render()
    }

    public func controlTextDidChange(_ notification: Notification) { review.invalidate() }

    @objc private func inputChanged(_ sender: Any?) { review.invalidate() }

    @objc public func reviewAction(_ sender: Any?) {
        review.review(.init(
            kind: selectedKind,
            name: name.stringValue,
            value: value.stringValue,
            message: message.stringValue,
            allowUnmerged: selectedKind == .deleteBranch && allowUnmerged.state == .on
        ))
    }

    @objc public func applyAction(_ sender: Any?) { if review.canApply, let plan = review.plan { start?(plan) } }

    @objc private func cancel(_ sender: Any?) { close?() }

    private func render() {
        reviewButton.isEnabled = review.workspace.canMutate && review.state != .loading
        apply.isEnabled = review.canApply
        apply.title = review.plan?.request.kind.isNetwork == true
            ? "Delete reviewed remote reference"
            : "Apply reviewed local action"
        summary.stringValue = review.plan?.summary ?? review.state.explanation
        summary.toolTip = summary.stringValue
    }

    public func disconnect() {
        if let subscription { review.unsubscribe(subscription) }
        review.stop()
    }
}
