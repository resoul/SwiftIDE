import AppKit
import IDEApplication

@MainActor
public final class GitChangesViewController: NSViewController, NSTextViewDelegate {
    public let model: GitWorkspace
    public var openFile: ((String) -> Void)?
    public var focusTarget: NSView { list.table }
    let list = GitListView(label: "Git changes on disk and in the index")
    private let status = NSTextField(wrappingLabelWithString: "")
    let stage = NSButton(title: "Stage file", target: nil, action: nil)
    let unstage = NSButton(title: "Unstage", target: nil, action: nil)
    let commit = NSButton(title: "Commit staged", target: nil, action: nil)
    let message = NSTextView()
    private var operation: GitOperationView?
    private var commitForm: NSStackView?
    private let compose = NSButton(title: "Commit…", target: nil, action: nil)
    private var lastOperationState = GitOperationState.idle
    private var subscription: UUID?
    private var comparisons: [String: GitComparison] = [:]

    public init(model: GitWorkspace) { self.model = model; super.init(nibName: nil, bundle: nil) }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func loadView() {
        view = NSView()
        let refresh = NSButton(title: "Refresh", target: self, action: #selector(refreshGit(_:)))
        let header = gitStack([NSTextField(labelWithString: "Changes"), NSView(), refresh], vertical: false)
        stage.target = self; stage.action = #selector(stageSelected(_:))
        unstage.target = self; unstage.action = #selector(unstageSelected(_:))
        commit.target = self; commit.action = #selector(commitStaged(_:))
        compose.target = self; compose.action = #selector(composeCommit(_:))
        stage.toolTip = "Stage the whole file from disk, replacing any partial staging"
        message.isRichText = false; message.font = .systemFont(ofSize: 12)
        message.delegate = self
        message.setAccessibilityLabel("Commit message")
        let messageScroll = NSScrollView(); messageScroll.documentView = message; messageScroll.hasVerticalScroller = true
        messageScroll.heightAnchor.constraint(equalToConstant: 70).isActive = true
        let mutationNote = NSTextField(wrappingLabelWithString: "Stage uses disk text. Commit includes ALL staged files and runs configured hooks/signing. Cancelling does not roll back changes.")
        mutationNote.font = .systemFont(ofSize: 10); mutationNote.textColor = .secondaryLabelColor
        let commitForm = gitStack([NSTextField(labelWithString: "Commit message"), messageScroll, commit, mutationNote])
        commitForm.isHidden = true; self.commitForm = commitForm
        let actions = gitStack([gitStack([stage, unstage, compose], vertical: false), commitForm])
        actions.isHidden = !model.supportsLocalActions
        let operation = GitOperationView(model: model); self.operation = operation
        let note = NSTextField(wrappingLabelWithString: "Diff compares disk and index. Unsaved editor text is separate. Double-click to open the file.")
        note.font = .systemFont(ofSize: 11); note.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 11)
        status.maximumNumberOfLines = 2; status.lineBreakMode = .byTruncatingMiddle
        gitPin(gitStack([header, list, actions, operation, status, note]), to: view, inset: 10)
        list.onSelect = { [weak self] key in
            guard let self, let comparison = comparisons[key] else { return }

            model.inspect(comparison)
            updateActions()
        }
        list.onOpen = { [weak self] key in
            guard let self, let comparison = comparisons[key], let repository = model.snapshot?.repository else { return }

            openFile?(repository.absolutePath(comparison.path))
        }
        subscription = model.subscribe { [weak self] in self?.render() }
        render()
    }
    @objc private func refreshGit(_ sender: Any?) { model.refresh() }
    @objc func stageSelected(_ sender: Any?) {
        guard let key = list.selectedKey, let comparison = comparisons[key], stage.isEnabled else { return }

        if case .worktree(let change) = comparison { model.perform(.stage(change)) }
        if case .untracked(let change) = comparison { model.perform(.stage(change)) }
    }
    @objc func unstageSelected(_ sender: Any?) {
        guard let key = list.selectedKey, case .index(let change) = comparisons[key], unstage.isEnabled else { return }

        model.perform(.unstage(change))
    }
    @objc func commitStaged(_ sender: Any?) {
        guard commit.isEnabled else { return }

        model.perform(.commit(message.string))
    }
    @objc private func composeCommit(_ sender: Any?) {
        if commitForm?.isHidden == false { commitForm?.isHidden = true; updateActions() }
        else { focusCommitMessage() }
    }
    public func focusCommitMessage() {
        commitForm?.isHidden = false
        updateActions()
        view.window?.makeFirstResponder(message)
    }
    private func updateActions() {
        let key = list.selectedKey ?? ""
        stage.isEnabled = model.canMutate && (key.hasPrefix("worktree:") || key.hasPrefix("untracked:") || key.hasPrefix("conflicts:"))
        unstage.isEnabled = model.canMutate && key.hasPrefix("index:")
        compose.title = commitForm?.isHidden == false ? "Hide message" : "Commit…"
        compose.isEnabled = model.canMutate
        message.isEditable = !model.operationState.isBusy
        commit.isEnabled = model.canMutate && !(message.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            && model.snapshot?.changes.contains(where: { !$0.decoration.index.isEmpty }) == true
            && model.snapshot?.changes.contains(where: { $0.decoration.isConflict }) == false
    }
    public func textDidChange(_ notification: Notification) { updateActions() }
    private func render() {
        status.stringValue = model.explanation
        status.toolTip = model.explanation
        var rows: [GitListRow] = []; comparisons = [:]
        let changes = model.snapshot?.changes.filter { $0.decoration.ignoredReason == nil } ?? []
        for (group, title) in ["conflicts": "Conflicts", "index": "Staged", "worktree": "Working tree", "untracked": "Untracked"].sorted(by: { order($0.key) < order($1.key) }) {
            var values: [GitListRow] = []
            for change in changes.sorted(by: { $0.path.localizedStandardCompare($1.path) == .orderedAscending }) {
                let d = change.decoration
                let matches = switch group {
                case "conflicts": d.isConflict
                case "index": !d.isConflict && !d.index.isEmpty
                case "worktree": !d.isConflict && !d.worktree.isEmpty
                default: d.isUntracked
                }
                guard matches else { continue }

                let key = group + ":" + change.path
                comparisons[key] = group == "index" ? .index(change) : group == "untracked" ? .untracked(change) : .worktree(change)
                values.append(GitListRow(key: key, title: change.path, detail: [change.previousPath.map { "from " + $0 }, d.explanation, change.submodule != "N..." ? "Submodule: " + change.submodule : nil].compactMap { $0 }.joined(separator: " · "), colour: d.tone.colour, selectable: true))
            }
            if !values.isEmpty { rows.append(.init(key: "group:" + group, title: "\(title) (\(values.count))", selectable: false)); rows += values }
        }
        if rows.isEmpty, model.state == .ready { rows = [.init(key: "empty", title: "No changes on disk or in the index", selectable: false)] }
        list.present(rows)
        if model.operationState == .succeeded, lastOperationState != .succeeded, model.operationTitle == GitLocalAction.commit("").title { message.string = ""; commitForm?.isHidden = true }
        lastOperationState = model.operationState
        updateActions(); operation?.render()
    }
    private func order(_ key: String) -> Int { ["conflicts", "index", "worktree", "untracked"].firstIndex(of: key) ?? 4 }
    public func disconnect() { if let subscription { model.unsubscribe(subscription) }; subscription = nil }
}
