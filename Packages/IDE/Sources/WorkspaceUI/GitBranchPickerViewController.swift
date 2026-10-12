import AppKit
import IDEApplication

@MainActor
public final class GitBranchPickerViewController: NSViewController, NSTextFieldDelegate {
    public let model: GitWorkspace
    public var onTrackingRequested: ((GitBranch?) -> Void)?
    let tracking = NSButton(title: "Tracking…", target: nil, action: nil)
    public var onIntegrateRequested: ((GitIntegrationKind, GitBranch?) -> Void)?
    let merge = NSButton(title: "Merge…", target: nil, action: nil)
    let rebase = NSButton(title: "Rebase…", target: nil, action: nil)
    public var onPullRequested: ((String?, String?) -> Void)?
    let pull = NSButton(title: "Pull…", target: nil, action: nil)
    public var onPushRequested: ((GitBranch?, String?) -> Void)?
    let push = NSButton(title: "Push…", target: nil, action: nil)
    public var onViewHistory: (() -> Void)?
    public var onActionStarted: (() -> Void)?
    let remote = NSPopUpButton(frame: .zero, pullsDown: false)
    let fetch = NSButton(title: "Fetch", target: nil, action: nil)
    let switchBranch = NSButton(title: "Switch local branch", target: nil, action: nil)
    let branchName = NSTextField(string: "")
    let createBranch = NSButton(title: "Create at HEAD", target: nil, action: nil)
    let button = NSButton(title: "Git", target: nil, action: nil)
    let search = NSSearchField()
    let list = GitListView(label: "Local and remote branch references")
    private let history = NSButton(title: "View history", target: nil, action: nil)
    private let popover = NSPopover()
    private var subscription: UUID?

    public init(model: GitWorkspace) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func loadView() {
        view = NSView()
        gitPin(button, to: view)
        button.image = WorkspaceIcon.image("tabler:git-branch", description: nil)
        button.imagePosition = .imageLeading
        button.bezelStyle = .inline
        button.imageScaling = .scaleProportionallyDown
        button.target = self
        button.action = #selector(showBranches(_:))
        search.placeholderString = "Search local and remote branches"
        search.target = self
        search.action = #selector(filterChanged(_:))
        search.sendsSearchStringImmediately = true
        history.target = self
        history.action = #selector(viewHistory(_:))
        switchBranch.target = self
        switchBranch.action = #selector(switchSelected(_:))
        createBranch.target = self
        createBranch.action = #selector(createNamed(_:))
        tracking.target = self
        tracking.action = #selector(trackingSelected(_:))
        branchName.placeholderString = "New branch name"
        branchName.delegate = self
        merge.target = self
        merge.action = #selector(mergeSelected(_:))
        rebase.target = self
        rebase.action = #selector(rebaseSelected(_:))
        pull.target = self
        pull.action = #selector(pullSelected(_:))
        push.target = self
        push.action = #selector(pushSelected(_:))
        fetch.target = self
        fetch.action = #selector(fetchSelected(_:))
        remote.target = self
        remote.action = #selector(remoteChanged(_:))
        remote.setAccessibilityLabel("Remote to fetch")
        fetch.toolTip = "Fetch branch refs only; keeps local branches, index and working files unchanged"
        let network = gitStack([remote, fetch, pull, push], vertical: false)
        network.isHidden = !model.supportsLocalActions
        let mutations = gitStack([switchBranch, gitStack([branchName, createBranch], vertical: false)])
        mutations.isHidden = !model.supportsLocalActions
        let note =
            NSTextField(
                wrappingLabelWithString: "Inspect locally known references. Remote data reflects previous fetches."
            )
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        let content = NSViewController()
        content.view = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 520))
        gitPin(
            gitStack([
                search,
                list,
                note,
                network,
                gitStack([merge, rebase, tracking], vertical: false),
                history,
                mutations
            ]),
            to: content.view,
            inset: 12
        )
        popover.contentViewController = content
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 420, height: 520)
        list.onSelect = { [weak self] _ in self?.updateActions() }
        list.onOpen = { [weak self] _ in self?.viewHistory(nil) }
        subscription = model.subscribe { [weak self] in self?.render() }
        render()
    }

    public func showRemoteSelection() {
        _ = view
        showBranches(nil)
    }

    @objc private func showBranches(_ sender: Any?) {
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        popover.contentViewController?.view.window?.makeFirstResponder(search)
    }

    @objc private func filterChanged(_ sender: Any?) { render() }

    @objc func viewHistory(_ sender: Any?) {
        guard let reference = list.selectedKey,
              let branch = model.snapshot?.branches.first(where: { $0.reference == reference }),
              model.state == .ready else {
            return
        }

        model.viewHistory(of: branch)
        onViewHistory?()
        popover.close()
    }

    @objc func switchSelected(_ sender: Any?) {
        guard switchBranch.isEnabled, let branch = selectedBranch else { return }

        popover.close()
        onActionStarted?()
        model.perform(.switchBranch(branch))
    }

    @objc func createNamed(_ sender: Any?) {
        guard createBranch.isEnabled else { return }

        let name = branchName.stringValue
        popover.close()
        onActionStarted?()
        model.perform(.createBranch(name))
    }

    @objc func fetchSelected(_ sender: Any?) {
        guard fetch.isEnabled, let name = remote.titleOfSelectedItem else { return }

        popover.close()
        onActionStarted?()
        model.perform(.fetch(name))
    }

    @objc func trackingSelected(_ sender: Any?) {
        if tracking.isEnabled {
            popover.close()
            onTrackingRequested?(selectedBranch)
        }
    }

    @objc func mergeSelected(_ sender: Any?) {
        if merge.isEnabled {
            popover.close()
            onIntegrateRequested?(.merge, selectedBranch)
        }
    }

    @objc func rebaseSelected(_ sender: Any?) {
        if rebase.isEnabled {
            popover.close()
            onIntegrateRequested?(.rebase, selectedBranch)
        }
    }

    @objc func pullSelected(_ sender: Any?) {
        guard pull.isEnabled else { return }

        let name = remote.titleOfSelectedItem
        if selectedBranch?.isRemote != true {
            popover.close()
            onPullRequested?(nil, nil)

            return
        }

        let prefix = "refs/remotes/" + (name ?? "") + "/"
        let source = selectedBranch.flatMap {
            $0.reference.hasPrefix(prefix) ? String($0.reference.dropFirst(prefix.count)) : nil
        }
        popover.close()
        onPullRequested?(name, source)
    }

    @objc func pushSelected(_ sender: Any?) {
        guard push.isEnabled else { return }

        popover.close()
        let local = selectedBranch?.isRemote == false ? selectedBranch : nil
        onPushRequested?(local, local?.trackingSuggestion(in: model.snapshot?.remotes ?? [])?.remote)
    }

    @objc private func remoteChanged(_ sender: Any?) { updateActions() }

    private var selectedBranch: GitBranch? { model.snapshot?.branches.first { $0.reference == list.selectedKey } }

    private func updateActions() {
        tracking.isHidden = model.trackingPlanner == nil
        tracking.isEnabled = model.canMutate && model.trackingPlanner != nil && model.snapshot?.integration == nil
        merge.isEnabled = model.canMutate && model.conflictReader != nil && model.snapshot?.integration == nil && model
            .snapshot?.branch != nil && selectedBranch != nil && selectedBranch?.name != model.snapshot?.branch
        rebase.isEnabled = merge.isEnabled
        pull.isHidden = model.pullPlanner == nil
        pull.isEnabled = model.canMutate && model.pullPlanner != nil && remote.titleOfSelectedItem != nil && model
            .snapshot?.branch != nil && model.snapshot?.head != nil
        push.isHidden = model.pushPlanner == nil
        push.isEnabled = model.canMutate && model.pushPlanner != nil && remote.titleOfSelectedItem != nil && model
            .snapshot?.branches.contains(where: { !$0.isRemote }) == true
        fetch.isEnabled = model.canMutate && remote.titleOfSelectedItem != nil
        remote.isEnabled = model.canMutate
        history.isEnabled = model.state == .ready && list.selectedKey != nil && !model.operationState.isBusy
        switchBranch.isEnabled = model.canMutate && selectedBranch?.isRemote == false && selectedBranch?.name != model
            .snapshot?.branch
        createBranch.isEnabled = model.canMutate && model.snapshot?.head != nil && !branchName.stringValue.isEmpty
        branchName.isEnabled = model.canMutate
    }

    public func controlTextDidChange(_ notification: Notification) { updateActions() }

    private func render() {
        button.title = model.snapshot?.headDescription ?? "Git"
        button.isEnabled = model.state == .ready && !model.operationState.isBusy
        let tracking = model.snapshot.flatMap { snapshot -> String? in
            guard let upstream = snapshot.upstream else { return nil }

            let counts: String
            if let ahead = snapshot.ahead, let behind = snapshot.behind { counts = "ahead \(ahead), behind \(behind)" }
            else { counts = "ahead/behind unknown" }

            return "Tracks " + upstream + " · " + counts + " · locally known refs"
        }
        let fetched = model.lastFetch.map {
            let time = $0.date.formatted(date: .omitted, time: .standard)

            return "Fetched " + $0.remote + " at " + time + " in this window; refs may change again"
        }
        button.toolTip = [model.explanation, tracking, fetched].compactMap { $0 }.joined(separator: "\n")
        button.setAccessibilityLabel("Git: " + button.title + ". Inspect branches and history")
        let selectedRemote = remote.titleOfSelectedItem
        let names = model.snapshot?.remotes ?? []
        if remote.itemTitles != names {
            remote.removeAllItems()
            remote.addItems(withTitles: names)
            if let selectedRemote, names.contains(selectedRemote) { remote.selectItem(withTitle: selectedRemote) }
        }

        let query = search.stringValue
        list
            .present((model.snapshot?.branches ?? [])
                .filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }.map {
                    .init(
                        key: $0.reference,
                        title: $0.name,
                        detail: ($0.isRemote ? "Remote" : "Local") + ($0.upstream.isEmpty
                            ? ""
                            : " · tracks " + $0.upstream),
                        selectable: true
                    )
                })
        updateActions()
    }

    public func disconnect() {
        if let subscription { model.unsubscribe(subscription) }
        subscription = nil
        popover.close()
    }
}
