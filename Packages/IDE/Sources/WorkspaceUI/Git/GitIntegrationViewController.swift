import AppKit
import IDEApplication

@MainActor
public final class GitIntegrationViewController: NSViewController {
    public let workspace: GitWorkspace
    public let kind: GitIntegrationKind
    public var start: ((GitIntegrationPlan) -> Void)?
    public var close: (() -> Void)?
    let target = NSPopUpButton(frame: .zero, pullsDown: false)
    let review = NSButton(title: "Review", target: nil, action: nil)
    let apply = NSButton(title: "", target: nil, action: nil)
    private let preserveMerges = NSButton(checkboxWithTitle: "Preserve merge topology", target: nil, action: nil)
    private let detail = NSTextField(wrappingLabelWithString: "Choose a locally known branch and Review.")
    private var branches: [GitBranch] = []
    private var plan: GitIntegrationPlan?
    private var subscription: UUID?

    public init(workspace: GitWorkspace, kind: GitIntegrationKind) {
        self.workspace = workspace
        self.kind = kind
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func loadView() {
        view = GitContextBackground(frame: NSRect(x: 0, y: 0, width: 620, height: 280))
        let title = NSTextField(labelWithString: kind.rawValue.capitalized + " Branch")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        target.target = self
        target.action = #selector(selectionChanged(_:))
        target.setAccessibilityLabel("Locally known integration target")
        review.target = self
        review.action = #selector(reviewTarget(_:))
        apply.title = kind.rawValue.capitalized
        apply.target = self
        apply.action = #selector(applyReviewed(_:))
        preserveMerges.isHidden = kind != .rebase
        preserveMerges.target = self
        preserveMerges.action = #selector(selectionChanged(_:))
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(closeForm(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let note = NSTextField(wrappingLabelWithString: kind == .merge
            ? """
            Merge preserves history and stops before committing. Resolve conflicts, then Continue with a merge commit \
            message. Saves/cancels open documents; requires clean tracked files. No Fetch or stash.
            """
            :
            """
            Rebase rewrites current branch commits onto the selected commit. Avoid rebasing published history. \
            Enable Preserve merge topology to recreate merge commits. Conflicts/empty commits \
            stop for Resolve/Continue/Skip/Abort. No Push, Fetch or stash.
            """)
        note.font = .systemFont(ofSize: 11)
        detail.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        detail.isSelectable = true
        gitPin(
            gitStack([title, target, preserveMerges, note, detail, gitStack([cancel, review, apply], vertical: false)]),
            to: view,
            inset: 16
        )
        subscription = workspace.subscribe { [weak self] in self?.render() }
        render()
    }

    public func select(_ branch: GitBranch?) {
        _ = view
        if let branch, let index = branches.firstIndex(of: branch) { target.selectItem(at: index) }
        selectionChanged(nil)
    }

    @objc private func selectionChanged(_ sender: Any?) {
        plan = nil
        detail.stringValue = "Choose a locally known branch and Review."
        render()
    }

    @objc func reviewTarget(_ sender: Any?) {
        guard review.isEnabled, let snapshot = workspace.snapshot, let head = snapshot.head,
              let branch = snapshot.branch, branches.indices.contains(target.indexOfSelectedItem) else {
            return
        }

        let selected = branches[target.indexOfSelectedItem]
        plan = .init(
            repository: snapshot.repository,
            kind: kind,
            head: head,
            branch: branch,
            target: selected,
            preserveMerges: kind == .rebase && preserveMerges.state == .on
        )
        detail.stringValue = "Current: " + branch + " @ " + head + "\nTarget: " + selected.name + " @ " + selected
            .oid + "\nPreserve topology: " + ((plan?.preserveMerges == true) ? "Yes" : "No")
            + "\nRemote refs are locally known; Fetch separately if needed."
        render()
    }

    @objc func applyReviewed(_ sender: Any?) { if apply.isEnabled, let plan { start?(plan) } }

    @objc private func closeForm(_ sender: Any?) { close?() }

    private func render() {
        let previous = branches.indices.contains(target.indexOfSelectedItem)
            ? branches[target.indexOfSelectedItem].reference
            : nil
        let current = workspace.snapshot
        branches = (current?.branches ?? []).filter { $0.reference != "refs/heads/" + (current?.branch ?? "") }
        let names = branches.map { ($0.isRemote ? "Remote · " : "Local · ") + $0.name }
        if target.itemTitles != names {
            target.removeAllItems()
            target.addItems(withTitles: names)
            if let index = branches.firstIndex(where: { $0.reference == previous }) { target.selectItem(at: index) }
        }

        if let plan,
           current?.repository != plan.repository || current?.head != plan.head || current?.branch != plan
           .branch || current?.branches.contains(plan.target) != true || current?.integration != nil {
            self.plan = nil
            detail.stringValue = "Repository changed; Review again."
        }

        review.isEnabled = workspace.canMutate && current?.head != nil && current?.branch != nil && current?
            .integration == nil && !branches.isEmpty
        target.isEnabled = review.isEnabled
        apply.isEnabled = review.isEnabled && plan != nil
    }

    public func disconnect() {
        if let subscription { workspace.unsubscribe(subscription) }
        subscription = nil
    }
}
