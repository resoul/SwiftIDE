import AppKit
import IDEApplication

public extension WorkspaceTool {
    static let gitLog = WorkspaceTool(id: 101, title: "Git Log", symbol: "tabler:git-branch", zone: .bottom)
}

@MainActor
public final class GitLogViewController: NSViewController {
    public let model: GitWorkspace
    public var inspectCI: ((GitCommit) -> Void)? { didSet { if isViewLoaded { render() } } }
    let ci = NSButton(title: "CI…", target: nil, action: nil)
    private var ciReports: [String: String] = [:]
    private var ciOrder: [String] = []
    public var focusTarget: NSView { commits.table }
    let commits = GitListView(label: "Git commit history")
    let files = GitListView(label: "Files changed by selected commit")
    let search = NSSearchField()
    public let source = NSPopUpButton()
    private let status = NSTextField(labelWithString: "")
    private let details =
        NSTextField(
            wrappingLabelWithString: "Select a commit to see files. Merge commits compare against their first parent."
        )
    private let more = NSButton(title: "Load more", target: nil, action: nil)
    private var subscription: UUID?
    private var graphed: [GitCommit] = []
    private var graphRows: [String: GitGraphRow] = [:]

    public init(model: GitWorkspace) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func loadView() {
        view = PanelBackgroundView()
        search.placeholderString = "Filter loaded commits by text, hash or author"
        search.target = self
        search.action = #selector(filterChanged(_:))
        search.sendsSearchStringImmediately = true
        more.target = self
        more.action = #selector(loadMore(_:))
        source.addItems(withTitles: ["Current branch", "All known references"])
        source.target = self
        source.action = #selector(sourceChanged(_:))
        source.setAccessibilityLabel("History scope")
        source.item(at: 1)?.isEnabled = model.supportsAllHistory
        ci.target = self
        ci.action = #selector(inspectCommitCI(_:))
        let header = gitStack([source, search, more, ci], vertical: false)
        search.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(commits)
        split.addArrangedSubview(gitStack([details, files]))
        details.font = .systemFont(ofSize: 11)
        details.textColor = .secondaryLabelColor
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

    @objc private func inspectCommitCI(_ sender: Any?) {
        if ci.isEnabled, let commit = model.selectedCommit { inspectCI?(commit) }
    }

    public func presentCI(
        sha: String,
        checks: [GitHostingCheck],
        limited: Bool,
        receivedAt: Date,
        source: String = ""
    ) {
        let states = Set(checks.map(\.state))
        let state = checks.isEmpty
            ? "none reported"
            : limited
                ? "partial report"
                : !states.isDisjoint(with: ["failure", "failed", "error", "timed_out", "cancelled", "canceled"])
                    ? "failed/cancelled"
                    : !states.isDisjoint(with: ["pending", "queued", "running", "in_progress", "waiting_for_resource"])
                        ? "running/pending"
                        : states == ["success"] ? "passed" : "other results"
        ciReports[sha] = " · CI: " + state + (source.isEmpty ? "" : " · " + source) + " (" + receivedAt.formatted(
            date: .omitted,
            time: .shortened
        ) + ")"
        ciOrder.removeAll { $0 == sha }
        ciOrder.append(sha)
        if ciOrder.count > 100 { ciReports[ciOrder.removeFirst()] = nil }
        if isViewLoaded { render() }
    }

    @objc public func sourceChanged(_ sender: Any?) {
        if source.indexOfSelectedItem == 1 { model.viewAllHistory() } else { model.viewHeadHistory() }
    }

    private func render() {
        let query = search.stringValue
        if graphed != model.history {
            graphed = model.history
            graphRows = GitHistoryGraph.layout(model.history)
        }

        let graph = query.isEmpty ? graphRows : [:]
        commits.present(model.history.filter {
            query.isEmpty || [$0.oid, $0.author, $0.subject].contains { $0.localizedCaseInsensitiveContains(query) }
        }.map {
            .init(
                key: $0.oid,
                title: String($0.oid.prefix(8)) + " · " + $0.subject,
                detail: $0.author + " · " + $0.date.formatted(date: .abbreviated, time: .shortened) + refLabels($0)
                    + (ciReports[$0.oid] ?? ""),
                selectable: true,
                graph: graph[$0.oid]
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
                .explanation + "\nParents: " + commit.parents.map { String($0.prefix(12)) }.joined(separator: ", ")
        } else {
            details.stringValue = "Select a commit to see files. Merge commits compare against their first parent."
        }

        more.isEnabled = model.state == .ready && model.hasMoreHistory && model.historyState != .loading
        ci.isHidden = inspectCI == nil
        ci.isEnabled = inspectCI != nil && model.selectedCommit != nil && model.state == .ready
        let explanation = model.state == .ready ? model.historyState.explanation : model.explanation
        status.stringValue = model.historyTitle + " · " + explanation
            + " · \(model.history.count) loaded · locally known refs"
            + (!query.isEmpty ? " · graph hidden while filtering" : "")
            + (model.history.count >= 5000 ? " · 5000-row limit" : "")
        status.toolTip = status.stringValue
    }

    public func disconnect() {
        if let subscription { model.unsubscribe(subscription) }
        subscription = nil
    }

    private func refLabels(_ commit: GitCommit) -> String {
        let labels = (model.snapshot?.branches.filter { $0.oid == commit.oid }.map(\.name) ?? [])
            + (model.snapshot?.tags.filter { $0.commit == commit.oid }.map(\.name) ?? [])

        return labels.isEmpty ? "" : " · " + labels.joined(separator: ", ")
    }
}
