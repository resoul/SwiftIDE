import AppKit
import IDEApplication

@MainActor
public final class GitTrackingViewController: NSViewController, NSTextFieldDelegate {
    public let model: GitTrackingReview
    public var start: ((GitTrackingPlan) -> Void)?
    public var close: (() -> Void)?
    let mode = NSPopUpButton(frame: .zero, pullsDown: false)
    let local = NSPopUpButton(frame: .zero, pullsDown: false)
    let source = NSPopUpButton(frame: .zero, pullsDown: false)
    let name = NSTextField(string: "")
    let review = NSButton(title: "Review", target: nil, action: nil)
    let apply = NSButton(title: "Apply", target: nil, action: nil)
    let details = NSTextField(wrappingLabelWithString: "Choose branches and Review.")
    private var locals: [GitBranch] = [], sources: [GitBranch] = []
    private var subscription: UUID?

    public init(workspace: GitWorkspace) {
        model = GitTrackingReview(workspace: workspace)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func loadView() {
        view = GitContextBackground(frame: NSRect(x: 0, y: 0, width: 650, height: 430))
        let title = NSTextField(labelWithString: "Branch Tracking")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        mode.addItems(withTitles: ["Create local tracking branch", "Set or change upstream", "Remove upstream"])
        for control in [mode, local, source] {
            control.target = self
            control.action = #selector(selectionChanged(_:))
        }
        mode.setAccessibilityLabel("Tracking operation")
        local.setAccessibilityLabel("Local branch")
        source.setAccessibilityLabel("Fetched remote branch")
        name.placeholderString = "New local branch name"
        name.setAccessibilityLabel("New local branch name")
        name.delegate = self
        details.isSelectable = true
        details.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        details.maximumNumberOfLines = 8
        review.target = self
        review.action = #selector(reviewSelection(_:))
        apply.target = self
        apply.action = #selector(applyReviewed(_:))
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(closeForm(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let note =
            NSTextField(
                wrappingLabelWithString: """
                Uses fetched refs. Creating a branch keeps the current checkout; switch separately. \
                Tracking changes no files and performs no Fetch or Push.
                """
            )
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        gitPin(
            gitStack([
                title,
                mode,
                local,
                name,
                source,
                note,
                details,
                gitStack([cancel, review, apply], vertical: false)
            ]),
            to: view,
            inset: 16
        )
        subscription = model.subscribe { [weak self] in self?.render() }
        render()
    }

    public func select(_ branch: GitBranch?) {
        _ = view
        if let branch, branch.isRemote, let index = sources.firstIndex(of: branch) {
            mode.selectItem(at: 0)
            source.selectItem(at: index)
            let remote = model.workspace.snapshot?.remotes.sorted { $0.count > $1.count }
                .first { branch.name.hasPrefix($0 + "/") }
            name.stringValue = remote.map { String(branch.name.dropFirst($0.count + 1)) } ?? branch.name
        } else {
            mode.selectItem(at: 1)
            let preferred = branch?.reference ?? model.workspace.snapshot?.branch.map { "refs/heads/" + $0 }
            if let index = locals.firstIndex(where: { $0.reference == preferred }) { local.selectItem(at: index) }
            if let selectedLocal,
               let index = sources
               .firstIndex(where: { $0.reference == selectedLocal.upstream }) { source.selectItem(at: index) }
        }

        model.invalidate()
    }

    private var selectedLocal: GitBranch? { locals.indices.contains(local.indexOfSelectedItem)
        ? locals[local.indexOfSelectedItem]
        : nil
    }
    private var selectedSource: GitBranch? { sources.indices.contains(source.indexOfSelectedItem)
        ? sources[source.indexOfSelectedItem]
        : nil
    }

    @objc func selectionChanged(_ sender: Any?) { model.invalidate() }

    public func controlTextDidChange(_ notification: Notification) { model.invalidate() }

    @objc func reviewSelection(_ sender: Any?) {
        guard review.isEnabled else { return }

        switch mode.indexOfSelectedItem {
        case 0: if let selectedSource { model.review(.create(name: name.stringValue, source: selectedSource)) }
        case 1: if let selectedLocal, let selectedSource { model.review(.set(
                branch: selectedLocal,
                target: selectedSource
            )) }
        case 2: if let selectedLocal { model.review(.remove(branch: selectedLocal)) }
        default: break
        }
    }

    @objc func applyReviewed(_ sender: Any?) { if model.canApply, let plan = model.plan { start?(plan) } }

    @objc private func closeForm(_ sender: Any?) { close?() }

    private func render() {
        let oldLocal = selectedLocal?.reference, oldSource = selectedSource?.reference
        locals = (model.workspace.snapshot?.branches ?? []).filter { !$0.isRemote }
        sources = (model.workspace.snapshot?.branches ?? []).filter(\.isRemote)
        replace(local, branches: locals, previous: oldLocal)
        replace(source, branches: sources, previous: oldSource)
        let create = mode.indexOfSelectedItem == 0, remove = mode.indexOfSelectedItem == 2
        apply.title = create ? "Create branch" : remove ? "Remove upstream" : "Set upstream"
        local.isHidden = create
        name.isHidden = !create
        source.isHidden = remove
        let busy = model.workspace.operationState.isBusy
        for control in [mode, local, source] { control.isEnabled = !busy }
        name.isEnabled = !busy
        review.isEnabled = model.workspace.canMutate && model.workspace.trackingPlanner != nil && model.workspace
            .snapshot?.integration == nil && model.state != .loading && (create
                ? !name.stringValue.isEmpty && selectedSource != nil
                : selectedLocal != nil && (remove || selectedSource != nil))
        apply.isEnabled = model.canApply
        if let plan = model.plan {
            let previous = create ? nil : selectedLocal?.upstream.isEmpty == false ? selectedLocal?.upstream : nil
            details.stringValue = "Repository: " + plan.repository.root + "\nLocal: " + plan.request
                .name + "\nPrevious upstream: " + (previous ?? "none")
                + "\nRemote: " + (plan.remote ?? "none") + "\nRemote branch: " + (plan.remoteSource ?? "none")
                + (plan.request.source.map { "\nFetched ref: " + $0.reference + " @ " + $0.oid } ?? "")
        } else { details.stringValue = model.state == .idle ? "Choose branches and Review." : model.state.explanation }

        details.toolTip = details.stringValue
    }

    private func replace(_ control: NSPopUpButton, branches: [GitBranch], previous: String?) {
        if control.itemTitles != branches.map(\.name) {
            control.removeAllItems()
            control.addItems(withTitles: branches.map(\.name))
            if let index = branches.firstIndex(where: { $0.reference == previous }) { control.selectItem(at: index) }
        }
    }

    public func disconnect() {
        if let subscription { model.unsubscribe(subscription) }
        subscription = nil
        model.stop()
    }
}
