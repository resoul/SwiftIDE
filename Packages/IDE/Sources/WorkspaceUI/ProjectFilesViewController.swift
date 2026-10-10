import AppKit
import IDEApplication
import UniformTypeIdentifiers

@MainActor
public final class ProjectFilesViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    public let model: ProjectFiles
    public var openFile: ((String) -> Void)?
    private(set) var outline = FilesOutlineView()
    private var rows: [String: FileRow] = [:]
    private var subscription: UUID?
    private var rendering = false
    private let status = NSTextField(wrappingLabelWithString: "")
    private var scroll = NSScrollView()

    public init(model: ProjectFiles) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func loadView() {
        view = NSView()
        let title = NSTextField(labelWithString: "Files · " + (model.root as NSString).lastPathComponent)
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        title.toolTip = model.root
        let refresh = NSButton(title: "Refresh", target: self, action: #selector(refreshFiles(_:)))
        let header = NSStackView(views: [title, refresh])
        header.orientation = .horizontal
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("File"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.rowHeight = 25
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(openSelected(_:))
        outline.openSelection = { [weak self] in self?.openSelected(nil) }
        outline.setAccessibilityLabel("Project files")
        outline.menu = NSMenu()
        outline.menu?.delegate = self
        scroll.hasVerticalScroller = true
        scroll.documentView = outline
        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        status.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [header, scroll, status])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -10),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            status.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        subscription = model.subscribe { [weak self] in self?.render() }
        render()
        model.expand(model.root)
    }

    /// Explicit disposal by the owning window, including when only its last tab closes.
    public func disconnect() {
        if let subscription { model.unsubscribe(subscription) }
        subscription = nil
    }

    private func row(_ file: ProjectFile) -> FileRow {
        if let row = rows[file.path], row.file == file { return row }

        let row = FileRow(file: file)
        rows[file.path] = row

        return row
    }

    private func children(_ parent: FileRow?) -> [FileRow] {
        guard let parent else { return [row(ProjectFile(path: model.root, isDirectory: true))] }

        if let message = model.state(of: parent.file.path).message {
            return [FileRow(file: parent.file, message: message)]
        }

        let entries = model.children(of: parent.file.path)
        if entries.isEmpty { return [FileRow(file: parent.file, message: "Empty folder")] }

        return entries.map(row)
    }

    private func render() {
        guard isViewLoaded, !rendering else { return }

        rendering = true
        defer { rendering = false }
        let position = scroll.contentView.bounds.origin
        outline.reloadData()
        for path in model.expanded.sorted(by: { $0.count < $1.count }) {
            if let item = rows[path] { outline.expandItem(item) }
        }
        if let path = model.selection, let item = rows[path], outline.row(forItem: item) >= 0 {
            outline.selectRowIndexes(IndexSet(integer: outline.row(forItem: item)), byExtendingSelection: false)
        } else {
            outline.deselectAll(nil)
        }

        scroll.contentView.scroll(to: position)
        scroll.reflectScrolledClipView(scroll.contentView)
        status.stringValue = model.statusExplanation
    }

    public func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        children(item as? FileRow).count
    }

    public func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        children(item as? FileRow)[index]
    }

    public func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let row = item as? FileRow else { return false }

        return row.message == nil && row.file.canExpand
    }

    public func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        (item as? FileRow)?.message == nil
    }

    public func outlineViewItemDidExpand(_ notification: Notification) {
        guard !rendering, let row = notification.userInfo?["NSObject"] as? FileRow else { return }

        model.expand(row.file.path)
    }

    public func outlineViewItemDidCollapse(_ notification: Notification) {
        guard !rendering, let row = notification.userInfo?["NSObject"] as? FileRow else { return }

        model.collapse(row.file.path)
    }

    public func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !rendering else { return }

        model.select((outline.item(atRow: outline.selectedRow) as? FileRow)?.file.path)
    }

    public func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let row = item as? FileRow else { return nil }

        let decoration = model.decoration(for: row.file.path)
        let label = NSTextField(labelWithString: row.message ?? row.file.name)
        label.lineBreakMode = .byTruncatingMiddle
        label.textColor = row.message == nil ? decoration.tone.colour : .secondaryLabelColor
        let badge = NSTextField(labelWithString: row.message == nil ? decoration.badges : "")
        badge.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        badge.setContentHuggingPriority(.required, for: .horizontal)
        let icon = NSImageView()
        if row.message == nil {
            // Generic extension icons avoid synchronous inspection of every path/network mount.
            icon.image = row.file.isDirectory ? NSImage(systemSymbolName: row.file.isSymbolicLink ? "folder.badge.questionmark" : "folder", accessibilityDescription: "Folder")
                : NSWorkspace.shared.icon(for: UTType(filenameExtension: (row.file.name as NSString).pathExtension) ?? .data)
        }

        let content = NSStackView(views: [icon, label, badge])
        content.orientation = .horizontal
        content.spacing = 6
        let cell = FileStatusCell(name: label, badge: badge, colour: label.textColor ?? .labelColor)
        content.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
            content.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 16).isActive = true
        let linkNote = row.file.isSymbolicLink ? "Symbolic link; linked folders are revealed in Finder, not expanded" : ""
        cell.toolTip = [row.file.path, row.message ?? decoration.explanation, linkNote].filter { !$0.isEmpty }.joined(separator: "\n")
        cell.setAccessibilityElement(true)
        cell.setAccessibilityLabel([row.message ?? row.file.name, decoration.explanation, linkNote].filter { !$0.isEmpty }.joined(separator: ", "))

        return cell
    }

    @objc private func refreshFiles(_ sender: Any?) { model.refresh() }

    @objc private func openSelected(_ sender: Any?) {
        guard let row = outline.item(atRow: outline.selectedRow) as? FileRow, row.message == nil else { return }

        if !row.file.isDirectory { openFile?(row.file.path) }
    }

    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let clicked = outline.clickedRow >= 0 ? outline.clickedRow : outline.selectedRow
        if let row = outline.item(atRow: clicked) as? FileRow, row.message == nil {
            add(menu, "Reveal in Finder", #selector(revealInFinder(_:)), path: row.file.path)
            if row.file.path != model.root {
                let excluded = model.exclusionRoot(for: row.file.path)
                let title = excluded.map { "Include \(($0 as NSString).lastPathComponent) in Project" } ?? "Exclude from Project"
                add(menu,
                    title,
                    excluded == nil ? #selector(exclude(_:)) : #selector(include(_:)),
                    path: row.file.path)
            }

            menu.addItem(.separator())
        }

        add(menu, "Show Excluded", #selector(toggleExcluded(_:)), checked: model.showExcluded)
        add(menu, "Show Ignored", #selector(toggleIgnored(_:)), checked: model.showIgnored)
        menu.items.last?.isEnabled = model.hasIgnoreInformation
        menu.items.last?.toolTip = model.hasIgnoreInformation ? nil : model.statusExplanation
        menu.autoenablesItems = false
        add(menu, "Refresh Files", #selector(refreshFiles(_:)))
    }

    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, path: String? = nil, checked: Bool = false) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = path
        item.state = checked ? .on : .off
        menu.addItem(item)
    }

    @objc private func revealInFinder(_ item: NSMenuItem) {
        guard let path = item.representedObject as? String else { return }

        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    @objc private func exclude(_ item: NSMenuItem) {
        if let path = item.representedObject as? String { model.exclude(path) }
    }

    @objc private func include(_ item: NSMenuItem) {
        if let path = item.representedObject as? String { model.include(path) }
    }

    @objc private func toggleExcluded(_ sender: Any?) { model.showExcluded.toggle() }
    @objc private func toggleIgnored(_ sender: Any?) { model.showIgnored.toggle() }
}

@MainActor
final class FileStatusCell: NSTableCellView {
    private let name: NSTextField
    private let badge: NSTextField
    private let colour: NSColor

    init(name: NSTextField, badge: NSTextField, colour: NSColor) {
        self.name = name
        self.badge = badge
        self.colour = colour
        super.init(frame: .zero)
        textField = name
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            name.textColor = backgroundStyle == .emphasized ? .alternateSelectedControlTextColor : colour
            badge.textColor = backgroundStyle == .emphasized ? .alternateSelectedControlTextColor : .labelColor
        }
    }
}

@MainActor
private final class FileRow: NSObject {
    let file: ProjectFile
    let message: String?
    init(file: ProjectFile, message: String? = nil) {
        self.file = file
        self.message = message
    }
}

@MainActor
final class FilesOutlineView: NSOutlineView {
    var openSelection: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 {
            openSelection?()

            return
        }

        super.keyDown(with: event)
    }
}
