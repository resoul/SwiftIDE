import AppKit
import IDEApplication

public extension WorkspaceTool {
    static let gitLog = WorkspaceTool(id: 101, title: "Git Log", symbol: "tabler:git-branch", zone: .bottom)
}

@MainActor
public final class GitLogViewController: NSViewController {
    public let model: GitWorkspace
    public var focusTarget: NSView { commits.table }
    let commits = GitListView(label: "Git commit history")
    let files = GitListView(label: "Files changed by selected commit")
    let search = NSSearchField()
    private let status = NSTextField(labelWithString: "")
    private let details =
        NSTextField(
            wrappingLabelWithString: "Select a commit to see files. Merge commits compare against their first parent."
        )
    private let more = NSButton(title: "Load more", target: nil, action: nil)
    private var subscription: UUID?

    public init(model: GitWorkspace) { self.model = model; super.init(nibName: nil, bundle: nil) }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func loadView() {
        view = NSView()
        search.placeholderString = "Filter loaded commits by text, hash or author"
        search.target = self; search.action = #selector(filterChanged(_:))
        search.sendsSearchStringImmediately = true
        more.target = self; more.action = #selector(loadMore(_:))
        let header = gitStack([search, more], vertical: false)
        search.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let split = NSSplitView(); split.isVertical = true; split.dividerStyle = .thin
        split.addArrangedSubview(commits)
        split.addArrangedSubview(gitStack([details, files]))
        details.font = .systemFont(ofSize: 11); details.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 11)
        status.lineBreakMode = .byTruncatingMiddle
        gitPin(gitStack([header, split, status]), to: view, inset: 10)
        commits.onSelect = { [weak self] oid in
            guard let self, let commit = model.history.first(where: { $0.oid == oid }) else { return }

            model.select(commit)
        }
        files.onSelect = { [weak self] path in
            guard let self, let commit = model.selectedCommit,
                  let file = model.commitFiles.first(where: { $0.path == path }) else {
                return
            }

            model.inspect(.commit(commit, file))
        }
        subscription = model.subscribe { [weak self] in self?.render() }
        render()
    }
    @objc private func filterChanged(_ sender: Any?) { render() }
    @objc private func loadMore(_ sender: Any?) { model.loadMoreHistory() }
    private func render() {
        let query = search.stringValue
        commits.present(model.history.filter {
            query.isEmpty || [$0.oid, $0.author, $0.subject].contains { $0.localizedCaseInsensitiveContains(query) }
        }.map {
            .init(
                key: $0.oid,
                title: String($0.oid.prefix(8)) + " · " + $0.subject,
                detail: $0.author + " · " + $0.date.formatted(date: .abbreviated, time: .shortened),
                selectable: true
            )
        })
        files.present(model.commitFiles.map {
            .init(
                key: $0.path,
                title: $0.status + " · " + $0.path,
                detail: $0.previousPath.map { "from " + $0 } ?? "",
                selectable: true
            )
        })
        if let commit = model.selectedCommit {
            details.stringValue = String(commit.oid.prefix(8)) + " · " + commit.subject + "\n" + model.filesState
                .explanation
        } else {
            details.stringValue = "Select a commit to see files. Merge commits compare against their first parent."
        }

        more.isEnabled = model.state == .ready && model.hasMoreHistory && model.historyState != .loading
        let explanation = model.state == .ready ? model.historyState.explanation : model.explanation
        status.stringValue = model.historyTitle + " · " + explanation
            + " · \(model.history.count) loaded · locally known refs"
        status.toolTip = status.stringValue
    }
    public func disconnect() { if let subscription { model.unsubscribe(subscription) }; subscription = nil }
}
