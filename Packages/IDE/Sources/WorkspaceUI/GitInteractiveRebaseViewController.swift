import AppKit
import IDEApplication

@MainActor
public final class GitInteractiveRebaseViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    public let model: GitInteractiveRebaseReview
    public var start: ((GitInteractiveRebasePlan) -> Void)?
    public var close: (() -> Void)?
    private let target = NSPopUpButton(frame: .zero, pullsDown: false)
    private let load = NSButton(title: "Load reviewed range", target: nil, action: nil)
    private let apply = NSButton(title: "Review and Rebase…", target: nil, action: nil)
    private let up = NSButton(title: "Move up", target: nil, action: nil)
    private let down = NSButton(title: "Move down", target: nil, action: nil)
    private let table = NSTableView()
    private let detail = NSTextField(wrappingLabelWithString: "")
    private var branches: [GitBranch] = []
    private var subscription: UUID?
    private let dragType = NSPasteboard.PasteboardType("com.swiftide.replay-step")

    public init(model: GitInteractiveRebaseReview) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func loadView() {
        view = GitContextBackground(frame: NSRect(x: 0, y: 0, width: 720, height: 520))
        let title = NSTextField(labelWithString: "Interactive Rebase")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        target.target = self
        target.action = #selector(targetChanged(_:))
        target.setAccessibilityLabel("Rebase target")
        load.target = self
        load.action = #selector(loadRange(_:))
        apply.target = self
        apply.action = #selector(startReviewed(_:))
        up.target = self
        up.action = #selector(moveStepUp(_:))
        down.target = self
        down.action = #selector(moveStepDown(_:))
        let column = NSTableColumn(identifier: .init("steps"))
        column.title = "Replay order · first to last"
        table.addTableColumn(column)
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 30
        table.registerForDraggedTypes([dragType])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        let note =
            NSTextField(
                wrappingLabelWithString: """
                Reorder by dragging or Move up/down. Squash combines messages; Fixup keeps the preceding \
                message. Edit pauses for changes. Drop explicitly removes a commit. Published history is \
                rewritten; nothing is pushed.
                """
            )
        note.font = .systemFont(ofSize: 11)
        detail.isSelectable = true
        detail.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(closeForm(_:)))
        cancel.keyEquivalent = "\u{1b}"
        gitPin(gitStack([
            title,
            gitStack([target, load], vertical: false),
            note,
            scroll,
            detail,
            gitStack([up, down, cancel, apply], vertical: false)
        ]), to: view, inset: 16)
        subscription = model.subscribe { [weak self] in self?.render() }
        render()
    }

    public func numberOfRows(in tableView: NSTableView) -> Int { model.plan?.steps.count ?? 0 }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let steps = model.plan?.steps, steps.indices.contains(row) else { return nil }

        let step = steps[row]
        let action = NSPopUpButton(frame: .zero, pullsDown: false)
        action.addItems(withTitles: GitReplayAction.allCases.map(\.rawValue))
        action.selectItem(withTitle: step.action.rawValue)
        action.tag = row
        action.target = self
        action.action = #selector(actionChanged(_:))
        action.setAccessibilityLabel("Replay action for " + step.commit.subject)
        let label = NSTextField(labelWithString: String(step.commit.oid.prefix(10)) + "  " + step.commit.subject)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        return gitStack([action, label], vertical: false)
    }

    public func tableViewSelectionDidChange(_ notification: Notification) { updateMoves() }

    public func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard let plan = model.plan, plan.steps.indices.contains(row) else { return nil }

        let item = NSPasteboardItem()
        item.setString(plan.token + "\n" + plan.steps[row].commit.oid, forType: dragType)

        return item
    }

    public func tableView(
        _ tableView: NSTableView,
        validateDrop info: any NSDraggingInfo,
        proposedRow row: Int,
        proposedDropOperation operation: NSTableView.DropOperation
    ) -> NSDragOperation {
        guard info.draggingSource as? NSTableView === table, operation == .above,
              model.workspace.canMutate, model.state == .ready else { return [] }

        return .move
    }

    public func tableView(
        _ tableView: NSTableView,
        acceptDrop info: any NSDraggingInfo,
        row: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        guard let text = info.draggingPasteboard.string(forType: dragType), let plan = model.plan else { return false }

        let fields = text.components(separatedBy: "\n")
        guard fields.count == 2, fields[0] == plan.token,
              let from = plan.steps.firstIndex(where: { $0.commit.oid == fields[1] }) else { return false }

        let to = max(0, min(plan.steps.count - 1, row > from ? row - 1 : row))
        model.move(from: from, to: to)
        table.selectRowIndexes(IndexSet(integer: to), byExtendingSelection: false)

        return true
    }

    @objc private func targetChanged(_ sender: Any?) { model.invalidate() }

    @objc private func loadRange(_ sender: Any?) {
        guard branches.indices.contains(target.indexOfSelectedItem) else { return }

        model.review(target: branches[target.indexOfSelectedItem])
    }

    @objc private func actionChanged(_ sender: NSPopUpButton) {
        guard let title = sender.titleOfSelectedItem, let action = GitReplayAction(rawValue: title) else { return }

        model.setAction(action, at: sender.tag)
    }

    @objc private func moveStepUp(_ sender: Any?) { move(-1) }

    @objc private func moveStepDown(_ sender: Any?) { move(1) }

    private func move(_ delta: Int) {
        let from = table.selectedRow, to = from + delta
        model.move(from: from, to: to)
        if model.plan?.steps.indices.contains(to) == true {
            table.selectRowIndexes(IndexSet(integer: to), byExtendingSelection: false)
        }
    }

    @objc private func startReviewed(_ sender: Any?) {
        if model.canApply, let plan = model.plan { start?(plan) }
    }

    @objc private func closeForm(_ sender: Any?) { close?() }

    private func render() {
        let previous = branches.indices.contains(target.indexOfSelectedItem)
            ? branches[target.indexOfSelectedItem].reference
            : nil
        let snapshot = model.workspace.snapshot
        branches = (snapshot?.branches ?? []).filter { $0.reference != "refs/heads/" + (snapshot?.branch ?? "") }
        let names = branches.map { ($0.isRemote ? "Remote · " : "Local · ") + $0.name }
        if target.itemTitles != names {
            target.removeAllItems()
            target.addItems(withTitles: names)
            if let index = branches.firstIndex(where: { $0.reference == previous }) { target.selectItem(at: index) }
        }

        let selected = table.selectedRow
        table.reloadData()
        if model.plan?.steps.indices.contains(selected) == true {
            table.selectRowIndexes(IndexSet(integer: selected), byExtendingSelection: false)
        }

        load.isEnabled = model.workspace.canMutate && model.state != .loading && !branches.isEmpty
        target.isEnabled = load.isEnabled
        table.isEnabled = model.workspace.canMutate && model.state == .ready
        apply.isEnabled = model.canApply
        detail.stringValue = model.plan?.validation ?? model.plan.map {
            "Current: " + $0.source.branch + " @ " + $0.source.head + "\nOnto: " + $0.source.target.name + " @ " + $0
                .source.target.oid
        } ?? model.state.explanation
        updateMoves()
    }

    private func updateMoves() {
        up.isEnabled = table.isEnabled && table.selectedRow > 0
        down.isEnabled = table.isEnabled && table.selectedRow >= 0 && table.selectedRow + 1 < table.numberOfRows
    }

    public func disconnect() {
        if let subscription { model.unsubscribe(subscription) }
        subscription = nil
        model.stop()
    }
}
