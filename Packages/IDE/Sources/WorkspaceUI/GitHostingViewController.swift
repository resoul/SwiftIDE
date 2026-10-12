import AppKit
import IDEApplication

@MainActor
public final class GitHostingViewController: NSViewController, NSTextFieldDelegate, NSTextViewDelegate {
    public let model: GitHostingWorkspace
    public var confirmCreate: ((GitHostingCreatePlan) -> Void)?
    public var openURL: ((URL) -> Void)?
    private let section = NSSegmentedControl(
        labels: ["Requests and CI", "Create PR/MR"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private var browse: NSStackView?
    private var compose: NSStackView?
    private let accounts = NSPopUpButton()
    private let remotes = NSPopUpButton()
    private let refresh = NSButton(title: "Refresh PR/MR and CI", target: nil, action: nil)
    private let stop = NSButton(title: "Stop", target: nil, action: nil)
    private let requests = GitListView(label: "Open pull/merge requests")
    private let checks = GitListView(label: "Commit CI checks")
    private let commitSHA = NSTextField(string: "")
    private let checksLabel = NSTextField(wrappingLabelWithString: "")
    private let source = NSTextField(string: "")
    private let target = NSTextField(string: "")
    private let titleField = NSTextField(string: "")
    private let body = NSTextView(usingTextLayoutManager: true)
    private let bodyUndo = UndoManager()
    private let draft = NSButton(checkboxWithTitle: "Draft", target: nil, action: nil)
    private let review = NSButton(title: "Review published source", target: nil, action: nil)
    private let create = NSButton(title: "Create PR/MR…", target: nil, action: nil)
    private let notice = NSTextField(wrappingLabelWithString: "")
    private var ids: [UUID] = []
    private var subscription: UUID?
    private var displayedRequests: [GitHostingRequest] = []
    private var displayedChecks: [GitHostingCheck] = []

    public init(model: GitHostingWorkspace) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func loadView() {
        view = GitContextBackground(frame: NSRect(x: 0, y: 0, width: 800, height: 720))
        accounts.target = self
        accounts.action = #selector(repositoryChanged(_:))
        remotes.target = self
        remotes.action = #selector(repositoryChanged(_:))
        accounts.setAccessibilityLabel("Hosting account")
        remotes.setAccessibilityLabel("Repository remote")
        refresh.target = self
        refresh.action = #selector(refreshHosting(_:))
        stop.target = self
        stop.action = #selector(stopHosting(_:))
        commitSHA.placeholderString = "CI commit SHA (empty = local HEAD)"
        commitSHA.setAccessibilityLabel("Full CI commit SHA, empty for local HEAD")
        commitSHA.delegate = self
        source.placeholderString = "Published source branch"
        target.placeholderString = "Base/target branch"
        titleField.placeholderString = "PR/MR title"
        for field in [source, target, titleField] { field.delegate = self }
        source.setAccessibilityLabel("PR/MR source branch")
        target.setAccessibilityLabel("PR/MR base branch")
        titleField.setAccessibilityLabel("PR/MR title")
        draft.target = self
        draft.action = #selector(draftChanged(_:))
        body.isRichText = false
        body.isEditable = true
        body.allowsUndo = true
        body.delegate = self
        body.font = .systemFont(ofSize: 12)
        body.setAccessibilityLabel("PR/MR description, up to 64 KB")
        body.isVerticallyResizable = true
        body.autoresizingMask = [.width]
        body.textContainer?.widthTracksTextView = true
        let bodyScroll = NSScrollView.nonElastic()
        body.frame = NSRect(x: 0, y: 0, width: 700, height: 90)
        body.minSize = NSSize(width: 0, height: 90)
        body.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        bodyScroll.borderType = .bezelBorder
        bodyScroll.hasVerticalScroller = true
        bodyScroll.documentView = body
        bodyScroll.heightAnchor.constraint(equalToConstant: 90).isActive = true
        review.target = self
        review.action = #selector(reviewRequest(_:))
        create.target = self
        create.action = #selector(createRequest(_:))
        requests.onOpen = { [weak self] key in
            guard let self, let number = Int(key),
                  let request = model.requests.first(where: { $0.number == number }) else {
                return
            }

            openURL?(request.url)
        }
        checks.onOpen = { [weak self] key in
            guard let self, let index = Int(key), model.checks.indices.contains(index),
                  let url = model.checks[index].url else {
                return
            }

            openURL?(url)
        }
        requests.heightAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
        requests.heightAnchor.constraint(lessThanOrEqualToConstant: 240).isActive = true
        checks.heightAnchor.constraint(greaterThanOrEqualToConstant: 126).isActive = true
        checksLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        notice.font = .systemFont(ofSize: 11)
        notice.isSelectable = true
        let note =
            NSTextField(
                wrappingLabelWithString: """
                Lists open requests; Return/double-click opens the selected link. CI belongs to the SHA shown \
                below. Creation needs a local source branch already published to this repository; Push is \
                separate. The description is plain text/Markdown and never executed.
                """
            )
        note.font = .systemFont(ofSize: 11)
        let browsing = gitStack([requests, commitSHA, checksLabel, checks])
        let composing = gitStack([
            gitStack([source, target], vertical: false),
            titleField,
            bodyScroll,
            draft,
            gitStack([review, create], vertical: false)
        ])
        source.widthAnchor.constraint(equalTo: target.widthAnchor).isActive = true
        browse = browsing
        compose = composing
        composing.isHidden = true
        section.selectedSegment = 0
        section.target = self
        section.action = #selector(sectionChanged(_:))
        section.setAccessibilityLabel("Hosting view")
        gitPin(gitStack([
            gitStack([accounts, remotes, refresh, stop], vertical: false),
            note,
            section,
            browsing,
            composing,
            notice
        ]), to: view, inset: 16)

        subscription = model.subscribe { [weak self] in self?.render() }
        render()
    }

    @objc private func sectionChanged(_ sender: Any?) {
        browse?.isHidden = section.selectedSegment != 0
        compose?.isHidden = section.selectedSegment != 1
    }

    public func selectCommit(_ sha: String?) {
        _ = view
        commitSHA.stringValue = sha ?? ""
        model.invalidate()
    }

    public func undoManager(for view: NSTextView) -> UndoManager? { bodyUndo }

    public func controlTextDidChange(_ notification: Notification) { model.invalidate() }

    public func textDidChange(_ notification: Notification) { model.invalidate() }

    public func textView(
        _ textView: NSTextView,
        shouldChangeTextIn affectedCharRange: NSRange,
        replacementString: String?
    ) -> Bool {
        guard let replacementString else { return true }

        let current = textView.string as NSString
        guard affectedCharRange.location <= current.length,
              affectedCharRange.length <= current.length - affectedCharRange.location else {
            return false
        }

        return current.replacingCharacters(in: affectedCharRange, with: replacementString).utf8.count <= 64_000
    }

    @objc private func draftChanged(_ sender: Any?) { model.invalidate() }

    @objc private func repositoryChanged(_ sender: Any?) {
        let id = ids.indices.contains(accounts.indexOfSelectedItem) ? ids[accounts.indexOfSelectedItem] : nil
        model.select(account: id, remote: remotes.titleOfSelectedItem ?? "")
    }

    @objc private func refreshHosting(_ sender: Any?) {
        model.refresh(commit: commitSHA.stringValue.isEmpty ? nil : commitSHA.stringValue)
    }

    @objc private func stopHosting(_ sender: Any?) { model.cancel() }

    @objc private func reviewRequest(_ sender: Any?) {
        guard review.isEnabled, !body.hasMarkedText(), let sha = model.workspace.snapshot?.branches
            .first(where: { !$0.isRemote && $0.name == source.stringValue })?.oid else { return }

        model.review(.init(
            title: titleField.stringValue,
            body: body.string,
            source: source.stringValue,
            target: target.stringValue,
            sha: sha,
            draft: draft.state == .on
        ))
    }

    @objc private func createRequest(_ sender: Any?) {
        if create.isEnabled, !body.hasMarkedText(), let plan = model.plan { confirmCreate?(plan) }
    }

    private func render() {
        let old = ids.indices.contains(accounts.indexOfSelectedItem) ? ids[accounts.indexOfSelectedItem] : nil
        ids = model.accounts.accounts.map(\.id)
        let names = model.accounts.accounts.map {
            $0.service.rawValue + " · " + $0.login + " · " + ($0.webURL.host ?? "")
        }
        if accounts.itemTitles != names {
            accounts.removeAllItems()
            accounts.addItems(withTitles: names)
            if let index = ids.firstIndex(of: model.accountID ?? old ?? UUID()) { accounts.selectItem(at: index) }
        }

        let remoteNames = model.workspace.snapshot?.remotes ?? []
        if remotes.itemTitles != remoteNames {
            remotes.removeAllItems()
            remotes.addItems(withTitles: remoteNames)
            if remoteNames.contains(model.remote) { remotes.selectItem(withTitle: model.remote) }
        }

        let selected = ids.indices.contains(accounts.indexOfSelectedItem) ? ids[accounts.indexOfSelectedItem] : nil
        if model.accountID == nil, let selected, let remote = remotes.titleOfSelectedItem {
            model.select(account: selected, remote: remote)

            return
        }

        if source.stringValue.isEmpty { source.stringValue = model.workspace.snapshot?.branch ?? "" }
        if displayedRequests != model.requests {
            displayedRequests = model.requests
            requests.present(model.requests.map { .init(
                key: String($0.number),
                title: "#\($0.number) " + $0.title,
                detail: ($0.draft ? "Draft · " : "") + $0.source + " → " + $0.target
            ) })
        }

        if displayedChecks != model.checks {
            displayedChecks = model.checks
            checks.present(model.checks.enumerated().map { .init(
                key: String($0.offset),
                title: $0.element.name,
                detail: $0.element.state,
                colour: ["success", "neutral", "skipped"].contains($0.element.state)
                    ? .systemGreen
                    : ["failure", "failed", "error", "timed_out"].contains($0.element.state)
                        ? .systemRed
                        : .labelColor
            ) })
        }

        checksLabel.stringValue = model.checksSHA.isEmpty
            ? "CI: no commit loaded"
            : "CI commit: " + model.checksSHA
        notice.stringValue = model.notice
        let busy = model.state == .loading
        for control in [accounts, remotes, commitSHA, source, target, titleField, draft] as [NSControl] {
            control.isEnabled = !busy
        }
        body.isEditable = !busy
        refresh.isEnabled = model.canRead
        stop.isEnabled = busy
        review.isEnabled = model.canRead && !body.hasMarkedText() && !titleField.stringValue.isEmpty && !target
            .stringValue.isEmpty
            && model.workspace.snapshot?.branches
            .contains(where: { !$0.isRemote && $0.name == source.stringValue }) == true
        create.isEnabled = model.canCreate && !body.hasMarkedText()
    }

    public func disconnect() {
        if let subscription { model.unsubscribe(subscription) }
        subscription = nil
        model.stop()
    }
}
