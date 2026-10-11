import AppKit
import IDEApplication

@MainActor
public final class GitChangesViewController: NSViewController {
    public let model: GitWorkspace
    public var openFile: ((String) -> Void)?
    public var focusTarget: NSView { list.table }
    let list = GitListView(label: "Git changes on disk and in the index")
    private let status = NSTextField(wrappingLabelWithString: "")
    private var subscription: UUID?
    private var comparisons: [String: GitComparison] = [:]
    public init(model: GitWorkspace) { self.model = model; super.init(nibName: nil, bundle: nil) }
    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func loadView() {
        view = NSView()
        let refresh = NSButton(title: "Refresh", target: self, action: #selector(refreshGit(_:)))
        let header = gitStack([NSTextField(labelWithString: "Changes"), NSView(), refresh], vertical: false)
        let note = NSTextField(wrappingLabelWithString: "Diff compares disk and index. Unsaved editor text is separate. Double-click to open the file.")
        note.font = .systemFont(ofSize: 11); note.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 11)
        status.maximumNumberOfLines = 2; status.lineBreakMode = .byTruncatingMiddle
        gitPin(gitStack([header, list, status, note]), to: view, inset: 10)
        list.onSelect = { [weak self] key in
            guard let self, let comparison = comparisons[key] else { return }

            model.inspect(comparison)
        }
        list.onOpen = { [weak self] key in
            guard let self, let comparison = comparisons[key], let repository = model.snapshot?.repository else { return }

            openFile?(repository.absolutePath(comparison.path))
        }
        subscription = model.subscribe { [weak self] in self?.render() }
        render()
    }
    @objc private func refreshGit(_ sender: Any?) { model.refresh() }
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
    }
    private func order(_ key: String) -> Int { ["conflicts", "index", "worktree", "untracked"].firstIndex(of: key) ?? 4 }
    public func disconnect() { if let subscription { model.unsubscribe(subscription) }; subscription = nil }
}
