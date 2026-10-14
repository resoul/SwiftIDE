import AppKit
import UITheme
import IDEApplication

@MainActor
public final class ProjectFilesViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate,
    NSMenuDelegate {
    public let model: ProjectFiles
    public var openFile: ((String) -> Void)?
    private(set) var outline = FilesOutlineView()
    private var rows: [String: FileRow] = [:]
    private var subscription: UUID?
    private var rendering = false
    private var pendingRender: UUID?
    private var hasRendered = false
    /// AppKit sees a stable child snapshot until the next deferred update.
    private var displayedChildren: [String: [FileRow]] = [:]
    private let status = NSTextField(wrappingLabelWithString: "")
    private var scroll = NSScrollView.nonElastic()

    public init(model: ProjectFiles) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func loadView() {
        view = PanelBackgroundView()
        let title = NSTextField(labelWithString: (model.root as NSString).lastPathComponent)
        title.font = .systemFont(ofSize: FileNavigatorLayout.fontSize, weight: .semibold)
        title.lineBreakMode = .byTruncatingMiddle
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.toolTip = model.root
        let refresh = NSButton(title: "", target: self, action: #selector(refreshFiles(_:)))
        refresh.image = WorkspaceIcon.image("tabler:refresh", description: "Refresh files")
        refresh.image?.size = NSSize(width: FileNavigatorLayout.iconSize, height: FileNavigatorLayout.iconSize)
        refresh.imagePosition = .imageOnly
        refresh.isBordered = false
        refresh.toolTip = "Refresh files"
        refresh.setAccessibilityLabel("Refresh files")
        refresh.widthAnchor.constraint(equalToConstant: FileNavigatorLayout.refreshButtonSize).isActive = true
        refresh.heightAnchor.constraint(equalToConstant: FileNavigatorLayout.refreshButtonSize).isActive = true
        let header = NSStackView(views: [title, NSView(), refresh])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.distribution = .fill
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("File"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.backgroundColor = WorkspaceTheme.background
        outline.rowHeight = FileNavigatorLayout.rowHeight
        outline.indentationPerLevel = FileNavigatorLayout.indentationPerLevel
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
        status.maximumNumberOfLines = 2
        let stack = NSStackView(views: [header, scroll, status])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = FileNavigatorLayout.sectionSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: FileNavigatorLayout.panelInset),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -FileNavigatorLayout.panelInset),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: FileNavigatorLayout.panelInset),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -FileNavigatorLayout.panelInset),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            status.widthAnchor.constraint(equalTo: stack.widthAnchor),
            status.heightAnchor.constraint(equalToConstant: FileNavigatorLayout.statusHeight)
        ])
        subscription = model.subscribe { [weak self] in self?.scheduleRender() }
        render()
        model.expand(model.root)
    }

    /// Explicit disposal by the owning window, including when only its last tab closes.
    public func disconnect() {
        if let subscription { model.unsubscribe(subscription) }
        subscription = nil
        pendingRender = nil
    }

    private func row(_ file: ProjectFile) -> FileRow {
        if let row = rows[file.path], row.file == file { return row }

        let row = FileRow(file: file)
        rows[file.path] = row

        return row
    }

    private func children(_ parent: FileRow?) -> [FileRow] {
        if parent?.message != nil { return [] }
        if let parent, !parent.file.canExpand { return [] }
        let key = parent?.file.path ?? ""
        if let children = displayedChildren[key] { return children }

        let children = makeChildren(parent)
        displayedChildren[key] = children

        return children
    }

    private func makeChildren(_ parent: FileRow?) -> [FileRow] {
        if let parent {
            guard parent.file.canExpand else { return [] }

            let path = parent.file.path
            let state = model.state(of: path)
            var result = model.hasListing(of: path) ? model.children(of: path).map(row) : []
            let message: String?
            if case .failed = state {
                message = state.message
            } else if !model.hasListing(of: path) {
                message = state.message
            } else {
                message = result.isEmpty ? "Empty folder" : nil
            }

            if let message {
                let previous = displayedChildren[path]?.first { $0.message == message && $0.file == parent.file }
                result.append(previous ?? FileRow(file: parent.file, message: message))
            }

            return result
        }

        return [row(ProjectFile(path: model.root, isDirectory: true))]
    }

    private func scheduleRender() {
        guard pendingRender == nil, subscription != nil else { return }

        let token = UUID()
        pendingRender = token
        // Expand/collapse/selection notifications can arrive inside AppKit's recursive update.
        // Changing children there invalidates entries it is still traversing. Wait until it returns.
        DispatchQueue.main.async { [weak self] in
            guard let self, pendingRender == token else { return }

            pendingRender = nil
            render()
        }
    }

    private func render() {
        guard isViewLoaded, !rendering else { return }

        rendering = true
        defer { rendering = false }
        let position = scroll.contentView.bounds.origin
        let visible = outline.rows(in: outline.visibleRect)
        let anchors: [(FileRow, CGFloat)] = visible.location == NSNotFound
            ? []
            : (visible.location..<NSMaxRange(visible)).compactMap { index in
                guard let item = outline.item(atRow: index) as? FileRow else { return nil }

                return (item, outline.rect(ofRow: index).minY - position.y)
            }
        let previousChildren = displayedChildren
        // Retain removed placeholders/nodes until native batch/expansion operations finish.
        withExtendedLifetime(previousChildren) {
            if !hasRendered {
                outline.reloadData()
                hasRendered = true
            } else {
                for key in previousChildren.keys.sorted(by: { $0.count < $1.count }) {
                    let parent = key.isEmpty ? nil : rows[key]
                    guard key.isEmpty || parent != nil else { continue }

                    let old = displayedChildren[key] ?? []
                    let next = makeChildren(parent)
                    let changes = next.map(ObjectIdentifier.init).difference(from: old.map(ObjectIdentifier.init))
                    guard !changes.isEmpty else { continue }

                    displayedChildren[key] = next
                    guard parent == nil || outline.isItemExpanded(parent) else { continue }

                    var removed = IndexSet(), inserted = IndexSet()
                    for change in changes {
                        switch change {
                        case .remove(let index, _, _): removed.insert(index)
                        case .insert(let index, _, _): inserted.insert(index)
                        }
                    }
                    outline.beginUpdates()
                    if !removed.isEmpty { outline.removeItems(at: removed, inParent: parent, withAnimation: []) }
                    if !inserted.isEmpty { outline.insertItems(at: inserted, inParent: parent, withAnimation: []) }
                    outline.endUpdates()
                }
            }

            for item in rows.values where !model.expanded.contains(item.file.path) && outline.isItemExpanded(item) {
                outline.collapseItem(item)
            }
            for path in model.expanded.sorted(by: { $0.count < $1.count }) {
                if let item = rows[path], item.file.canExpand, outline.row(forItem: item) >= 0,
                   !outline.isItemExpanded(item) { outline.expandItem(item) }
            }
            if let path = model.selection, let item = rows[path], outline.row(forItem: item) >= 0 {
                outline.selectRowIndexes(IndexSet(integer: outline.row(forItem: item)), byExtendingSelection: false)
            } else {
                outline.deselectAll(nil)
            }
        }

        status.stringValue = model.statusExplanation
        view.layoutSubtreeIfNeeded()
        let anchor = anchors.first { anchorRow($0.0) >= 0 }
        let y = anchor.map { outline.rect(ofRow: anchorRow($0.0)).minY - $0.1 } ?? position.y
        scroll.contentView.scroll(to: NSPoint(x: position.x, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
        let updatedVisible = outline.rows(in: outline.visibleRect)
        if updatedVisible.location != NSNotFound {
            for index in updatedVisible.location..<NSMaxRange(updatedVisible) {
                if let item = outline.item(atRow: index) as? FileRow,
                   let cell = outline.view(atColumn: 0, row: index, makeIfNecessary: false) as? FileStatusCell {
                    cell.present(item.file, message: item.message, decoration: model.decoration(for: item.file.path))
                }
            }
        }
    }

    private func anchorRow(_ item: FileRow) -> Int {
        let index = outline.row(forItem: item)
        if index >= 0 { return index }
        guard item.message == nil, let current = rows[item.file.path] else { return -1 }

        return outline.row(forItem: current)
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

        let identifier = NSUserInterfaceItemIdentifier("FileStatus")
        let cell = outline.makeView(withIdentifier: identifier, owner: self) as? FileStatusCell ?? FileStatusCell()
        cell.identifier = identifier
        cell.present(row.file, message: row.message, decoration: model.decoration(for: row.file.path))

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
                let title = excluded.map { "Include \(($0 as NSString).lastPathComponent) in Project" }
                    ?? "Exclude from Project"
                add(
                    menu,
                    title,
                    excluded == nil ? #selector(exclude(_:)) : #selector(include(_:)),
                    path: row.file.path
                )
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
    private let name = NSTextField(labelWithString: "")
    private let badge = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    private var colour = NSColor.labelColor
    private var iconColour = WorkspaceTheme.fileIcon
    private var file: ProjectFile?
    private var isPlaceholder = false
    private var lastMessage: String?
    private var lastDecoration: FileDecoration?

    init() {
        super.init(frame: .zero)
        textField = name
        imageView = icon
        name.font = .systemFont(ofSize: FileNavigatorLayout.fontSize)
        name.lineBreakMode = .byTruncatingMiddle
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        icon.imageScaling = .scaleProportionallyDown
        badge.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        badge.setContentHuggingPriority(.required, for: .horizontal)
        let content = NSStackView(views: [icon, name, badge])
        content.orientation = .horizontal
        content.alignment = .centerY
        content.distribution = .fill
        content.spacing = FileNavigatorLayout.iconTextSpacing
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -FileNavigatorLayout.rowTrailingInset),
            content.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: FileNavigatorLayout.iconSize),
            icon.heightAnchor.constraint(equalToConstant: FileNavigatorLayout.iconSize)
        ])
        setAccessibilityElement(true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func present(_ file: ProjectFile, message: String?, decoration: FileDecoration) {
        guard self.file != file || lastMessage != message || lastDecoration != decoration else { return }

        if self.file != file || isPlaceholder != (message != nil) {
            let presentation = FileIcon(file: file)
            icon.image = message == nil ? presentation.image() : nil
            iconColour = presentation.tint
            icon.contentTintColor = backgroundStyle == .emphasized ? .alternateSelectedControlTextColor : iconColour
        }

        self.file = file
        lastMessage = message
        lastDecoration = decoration
        isPlaceholder = message != nil
        name.stringValue = message ?? file.name
        badge.stringValue = message == nil ? decoration.badges : ""
        badge.isHidden = badge.stringValue.isEmpty
        colour = message == nil ? decoration.tone.colour : .secondaryLabelColor
        name.textColor = backgroundStyle == .emphasized ? .alternateSelectedControlTextColor : colour
        badge.textColor = backgroundStyle == .emphasized ? .alternateSelectedControlTextColor : .labelColor
        let linkNote = file.isSymbolicLink ? "Symbolic link; linked folders are revealed in Finder, not expanded" : ""
        toolTip = [file.path, message ?? decoration.explanation, linkNote].filter { !$0.isEmpty }
            .joined(separator: "\n")
        setAccessibilityLabel([message ?? file.name, decoration.explanation, linkNote].filter { !$0.isEmpty }
            .joined(separator: ", "))
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            name.textColor = backgroundStyle == .emphasized ? .alternateSelectedControlTextColor : colour
            badge.textColor = backgroundStyle == .emphasized ? .alternateSelectedControlTextColor : .labelColor
            icon.contentTintColor = backgroundStyle == .emphasized ? .alternateSelectedControlTextColor : iconColour
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

    override func frameOfOutlineCell(atRow row: Int) -> NSRect {
        let frame = super.frameOfOutlineCell(atRow: row)
        guard !frame.isEmpty else { return frame }

        let size = FileNavigatorLayout.disclosureSize

        return NSRect(
            x: frame.midX - size / 2 + FileNavigatorLayout.disclosureHorizontalOffset,
            y: frame.midY - size / 2,
            width: size,
            height: size
        )
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 {
            openSelection?()

            return
        }

        super.keyDown(with: event)
    }
}
