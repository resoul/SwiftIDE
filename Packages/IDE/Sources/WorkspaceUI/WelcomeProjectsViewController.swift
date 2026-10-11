import AppKit
import IDEApplication

/// Welcome presentation only: callbacks connect opening/locating to the owning application.
@MainActor
public final class WelcomeProjectsViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSMenuDelegate {
    public let model: RecentProjects
    public var openFolder: (() -> Void)?
    public var openProject: ((String) -> Void)?
    public var locateProject: ((String) -> Void)?
    let search = NSSearchField()
    let table = RecentProjectsTable()
    private let version: String
    private let empty = NSTextField(wrappingLabelWithString: "")
    private let storage = NSTextField(wrappingLabelWithString: "")
    private let scroll = NSScrollView()
    private var rows: [RecentProject] = []
    private var subscription: UUID?
    private var rendering = false

    public init(model: RecentProjects, version: String) {
        self.model = model
        self.version = version
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func loadView() {
        view = WelcomeBackground(sidebar: false)
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 640)
        let sidebar = makeSidebar()
        sidebar.widthAnchor.constraint(equalToConstant: 224).isActive = true
        let separator = NSBox()
        separator.boxType = .separator
        separator.widthAnchor.constraint(equalToConstant: 1).isActive = true
        let content = makeContent()
        let root = welcomeStack([sidebar, separator, content], vertical: false)
        welcomePin(root, to: view)
        subscription = model.subscribe { [weak self] in self?.render() }
        render()
    }

    public func disconnect() {
        if let subscription { model.unsubscribe(subscription) }
        subscription = nil
    }

    public func focusSearch() { view.window?.makeFirstResponder(search) }

    private func makeSidebar() -> NSView {
        let icon = NSImageView(image: WorkspaceIcon.image("swift", description: "SwiftIDE") ?? NSImage())
        icon.contentTintColor = .systemOrange
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 38).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 38).isActive = true
        let title = NSTextField(labelWithString: "SwiftIDE")
        title.font = .systemFont(ofSize: 16, weight: .semibold)
        let build = NSTextField(labelWithString: version)
        build.font = .systemFont(ofSize: 11)
        build.textColor = .secondaryLabelColor
        let branding = welcomeStack([icon, welcomeStack([title, build], vertical: true, spacing: 4)], vertical: false, spacing: 12)
        let projects = NSButton(title: "Projects", target: self, action: #selector(focusProjects(_:)))
        projects.bezelStyle = .recessed
        projects.setButtonType(.pushOnPushOff)
        projects.state = .on
        projects.setAccessibilityLabel("Projects")
        let settings = NSButton(title: "Settings…", target: nil, action: nil)
        settings.image = WorkspaceIcon.image("gearshape", description: nil)
        settings.imagePosition = .imageLeading
        settings.bezelStyle = .inline
        settings.isEnabled = false
        settings.toolTip = "Settings are not available yet"
        let content = welcomeStack([branding, projects, NSView(), settings], vertical: true, spacing: 24)
        projects.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        let background = WelcomeBackground(sidebar: true)
        welcomePin(content, to: background, inset: 18)

        return background
    }

    private func makeContent() -> NSView {
        search.placeholderString = "Search projects"
        search.setAccessibilityLabel("Search projects by name or path")
        search.delegate = self
        search.target = self
        search.action = #selector(openSelected(_:))
        search.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let open = NSButton(title: "Open Folder…", target: self, action: #selector(chooseFolder(_:)))
        let header = welcomeStack([search, open], vertical: false, spacing: 14)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Project"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 76
        table.intercellSpacing = NSSize(width: 0, height: 4)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.style = .plain
        table.allowsMultipleSelection = false
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openSelected(_:))
        table.openSelection = { [weak self] in self?.openSelected(nil) }
        table.setAccessibilityLabel("Recent projects")
        table.menu = NSMenu()
        table.menu?.delegate = self
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        table.backgroundColor = .clear
        empty.alignment = .center
        empty.font = .systemFont(ofSize: 17)
        empty.textColor = .secondaryLabelColor
        let body = NSView()
        welcomePin(scroll, to: body)
        empty.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(empty)
        NSLayoutConstraint.activate([
            empty.centerXAnchor.constraint(equalTo: body.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: body.centerYAnchor),
            empty.widthAnchor.constraint(lessThanOrEqualTo: body.widthAnchor, constant: -30)
        ])
        storage.font = .systemFont(ofSize: 11)
        storage.textColor = .systemOrange
        let content = welcomeStack([header, body, storage], vertical: true, spacing: 18)
        for child in [header, body, storage] { child.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true }
        let outer = NSView()
        welcomePin(content, to: outer, inset: 24)

        return outer
    }

    private func render() {
        guard isViewLoaded, !rendering else { return }

        rendering = true
        defer { rendering = false }
        let origin = scroll.contentView.bounds.origin
        rows = model.visible
        table.reloadData()
        if let selection = model.selection, let index = rows.firstIndex(where: { $0.path == selection }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else {
            table.deselectAll(nil)
        }

        scroll.contentView.scroll(to: origin)
        scroll.reflectScrolledClipView(scroll.contentView)
        scroll.isHidden = rows.isEmpty
        empty.isHidden = !rows.isEmpty
        empty.stringValue = model.projects.isEmpty
            ? "Welcome to SwiftIDE\n\nOpen a project folder to begin.\nYour recent projects will appear here."
            : "No matching projects\n\nTry another name or path."
        storage.stringValue = model.storageIssue ?? ""
        storage.isHidden = model.storageIssue == nil
    }

    public func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    public func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { WelcomeProjectRow() }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }

        let entry = rows[row]
        let cell = WelcomeProjectCell()
        cell.configure(entry, open: model.openRoots.contains(entry.path), availability: model.availability[entry.path] ?? .checking)

        return cell
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        guard !rendering else { return }

        model.selection = rows.indices.contains(table.selectedRow) ? rows[table.selectedRow].path : nil
    }

    public func controlTextDidChange(_ notification: Notification) {
        model.query = search.stringValue
        if !rows.contains(where: { $0.path == model.selection }) {
            model.selection = rows.first?.path
            render()
        }
    }

    @objc private func chooseFolder(_ sender: Any?) { openFolder?() }
    @objc private func focusProjects(_ sender: Any?) { (sender as? NSButton)?.state = .on; focusSearch() }
    @objc func openSelected(_ sender: Any?) {
        guard rows.indices.contains(table.selectedRow) else { return }

        openProject?(rows[table.selectedRow].path)
    }

    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let index = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard rows.indices.contains(index) else { return }

        let entry = rows[index]
        for (title, action) in [("Open", #selector(openFromMenu(_:))),
                                (entry.isPinned ? "Unpin" : "Pin", #selector(pinFromMenu(_:))),
                                ("Locate Folder…", #selector(locateFromMenu(_:))),
                                ("Remove from Recent", #selector(removeFromMenu(_:)))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = entry.path
            menu.addItem(item)
        }
    }
    @objc private func openFromMenu(_ sender: NSMenuItem) { if let path = sender.representedObject as? String { openProject?(path) } }
    @objc private func pinFromMenu(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String, let entry = model.projects.first(where: { $0.path == path }) else { return }

        model.pin(path, pinned: !entry.isPinned)
    }
    @objc private func locateFromMenu(_ sender: NSMenuItem) { if let path = sender.representedObject as? String { locateProject?(path) } }
    @objc private func removeFromMenu(_ sender: NSMenuItem) { if let path = sender.representedObject as? String { model.remove(path) } }
}

@MainActor
final class RecentProjectsTable: NSTableView {
    var openSelection: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 {
            openSelection?()

            return
        }

        super.keyDown(with: event)
    }
}

@MainActor
final class WelcomeProjectCell: NSTableCellView {
    private let title = NSTextField(labelWithString: "")
    private let path = NSTextField(labelWithString: "")
    private let status = NSTextField(labelWithString: "")
    private var stateColour = NSColor.secondaryLabelColor

    init() {
        super.init(frame: .zero)
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        path.font = .systemFont(ofSize: 12)
        path.lineBreakMode = .byTruncatingMiddle
        status.font = .systemFont(ofSize: 11)
        let icon = NSImageView(image: WorkspaceIcon.image("folder.fill", description: nil) ?? NSImage())
        icon.contentTintColor = .controlAccentColor
        icon.widthAnchor.constraint(equalToConstant: 32).isActive = true
        let labels = welcomeStack([title, path, status], vertical: true, spacing: 4)
        let row = welcomeStack([icon, labels], vertical: false, spacing: 14)
        welcomePin(row, to: self, inset: 10)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(_ project: RecentProject, open: Bool, availability: ProjectFolderAvailability) {
        title.stringValue = project.name
        path.stringValue = (project.path as NSString).abbreviatingWithTildeInPath
        var notes: [String] = []
        if project.isPinned { notes.append("Pinned") }
        if open { notes.append("Open") }
        switch availability {
        case .checking: notes.append("Checking folder…")
        case .available: break
        case .missing: notes.append("Folder not found · Locate or remove from Recent"); stateColour = Self.warningColour
        case .unavailable(let reason): notes.append("Unavailable: " + reason); stateColour = Self.warningColour
        }
        status.stringValue = notes.joined(separator: " · ")
        toolTip = ([project.name, project.path] + notes).joined(separator: "\n")
        setAccessibilityLabel(toolTip)
        updateColours()
    }
    private func updateColours() {
        title.textColor = .labelColor
        path.textColor = .secondaryLabelColor
        status.textColor = stateColour
    }

    private static let warningColour = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? .systemOrange : NSColor(calibratedRed: 0.63, green: 0.33, blue: 0.06, alpha: 1)
    }
}

@MainActor
private final class WelcomeProjectRow: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.controlAccentColor.withAlphaComponent(0.22).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 2), xRadius: 6, yRadius: 6).fill()
        }
    }
}

@MainActor
private final class WelcomeBackground: NSView {
    private let sidebar: Bool
    init(sidebar: Bool) { self.sidebar = sidebar; super.init(frame: .zero); wantsLayer = true }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var wantsUpdateLayer: Bool { true }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = (sidebar ? NSColor.controlBackgroundColor : NSColor.windowBackgroundColor).cgColor
        }
    }
}

@MainActor
private func welcomeStack(_ views: [NSView], vertical: Bool, spacing: CGFloat = 0) -> NSStackView {
    let stack = NSStackView(views: views)
    stack.orientation = vertical ? .vertical : .horizontal
    stack.alignment = vertical ? .leading : .centerY
    stack.distribution = .fill
    stack.spacing = spacing
    for view in views {
        view.translatesAutoresizingMaskIntoConstraints = false
        if vertical { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        else { view.heightAnchor.constraint(equalTo: stack.heightAnchor).isActive = true }
    }

    return stack
}

@MainActor
private func welcomePin(_ view: NSView, to parent: NSView, inset: CGFloat = 0) {
    parent.addSubview(view)
    view.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
        view.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: inset),
        view.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -inset),
        view.topAnchor.constraint(equalTo: parent.topAnchor, constant: inset),
        view.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -inset)
    ])
}
