import AppKit
import IDEApplication

@MainActor
public final class GitBranchPickerViewController: NSViewController {
    public let model: GitWorkspace
    public var onViewHistory: (() -> Void)?
    let button = NSButton(title: "Git", target: nil, action: nil)
    let search = NSSearchField()
    let list = GitListView(label: "Local and remote branch references")
    private let history = NSButton(title: "View history", target: nil, action: nil)
    private let popover = NSPopover()
    private var subscription: UUID?
    public init(model: GitWorkspace) { self.model = model; super.init(nibName: nil, bundle: nil) }
    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    public override func loadView() {
        view = NSView(); gitPin(button, to: view)
        button.image = WorkspaceIcon.image("tabler:git-branch", description: nil)
        button.imagePosition = .imageLeading; button.bezelStyle = .inline
        button.imageScaling = .scaleProportionallyDown
        button.target = self; button.action = #selector(showBranches(_:))
        search.placeholderString = "Search local and remote branches"
        search.target = self; search.action = #selector(filterChanged(_:)); search.sendsSearchStringImmediately = true
        history.target = self; history.action = #selector(viewHistory(_:))
        let note = NSTextField(wrappingLabelWithString: "Inspect locally known references. Remote data reflects previous fetches.")
        note.font = .systemFont(ofSize: 11); note.textColor = .secondaryLabelColor
        let content = NSViewController(); content.view = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 400))
        gitPin(gitStack([search, list, note, history]), to: content.view, inset: 12)
        popover.contentViewController = content; popover.behavior = .transient
        popover.contentSize = NSSize(width: 380, height: 400)
        list.onSelect = { [weak self] _ in self?.history.isEnabled = self?.model.state == .ready }
        list.onOpen = { [weak self] _ in self?.viewHistory(nil) }
        subscription = model.subscribe { [weak self] in self?.render() }
        render()
    }
    @objc private func showBranches(_ sender: Any?) {
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        popover.contentViewController?.view.window?.makeFirstResponder(search)
    }
    @objc private func filterChanged(_ sender: Any?) { render() }
    @objc func viewHistory(_ sender: Any?) {
        guard let reference = list.selectedKey, let branch = model.snapshot?.branches.first(where: { $0.reference == reference }), model.state == .ready else { return }

        model.viewHistory(of: branch)
        onViewHistory?(); popover.close()
    }
    private func render() {
        button.title = model.snapshot?.headDescription ?? "Git"
        button.isEnabled = model.state == .ready
        let tracking = model.snapshot.flatMap { snapshot -> String? in
            guard let upstream = snapshot.upstream else { return nil }

            let counts: String
            if let ahead = snapshot.ahead, let behind = snapshot.behind { counts = "ahead \(ahead), behind \(behind)" }
            else { counts = "ahead/behind unknown" }

            return "Tracks " + upstream + " · " + counts + " · locally known refs"
        }
        button.toolTip = [model.explanation, tracking].compactMap { $0 }.joined(separator: "\n")
        button.setAccessibilityLabel("Git: " + button.title + ". Inspect branches and history")
        let query = search.stringValue
        list.present((model.snapshot?.branches ?? []).filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }.map {
            .init(key: $0.reference, title: $0.name, detail: ($0.isRemote ? "Remote" : "Local") + ($0.upstream.isEmpty ? "" : " · tracks " + $0.upstream), selectable: true)
        })
        history.isEnabled = model.state == .ready && list.selectedKey != nil
    }
    public func disconnect() { if let subscription { model.unsubscribe(subscription) }; subscription = nil; popover.close() }
}
