import AppKit
import UITheme
import IDEApplication

@MainActor
public final class ProjectFilesViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate,
    NSMenuDelegate {
    public let model: ProjectFiles
    public var openFile: ((String) -> Void)?
    /// Where Copy Path puts the text. The system pasteboard unless a test says otherwise.
    public var pasteboard: NSPasteboard = .general
    /// Asks whether to go on with a deletion: the title, what will happen, and the answer. Replaced
    /// in tests; the default is a sheet.
    public var confirmTrash: ((_ title: String, _ message: String, _ completion: @escaping (Bool) -> Void) -> Void)?
    /// The Git items for a file or folder (an absolute path); empty when the project has no Git.
    public var gitEntries: ((String) -> [FileMenuEntry])?
    /// Asks the user for a name and hands it to `submit`, which answers nil if it was accepted or a
    /// message to show beside the field. Replaced in tests; the default is a floating box.
    public var promptForName: ((_ prompt: NamePrompt, _ submit: @escaping (String) -> String?) -> Void)?
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
        installDragAndDrop()
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
            if model.canCreate { addNewSubmenu(to: menu, in: directory(of: row.file)) }

            let isRoot = row.file.path == model.root
            if !isRoot, model.canModifyItems { addClipboardItem(menu, "Cut", "x", #selector(cutClicked(_:)), row) }

            if !isRoot { addClipboardItem(menu, "Copy", "c", #selector(copyClicked(_:)), row) }

            add(menu, "Copy Path", #selector(copyPath(_:)), path: row.file.path)
            if !isRoot { add(menu, "Copy Relative Path", #selector(copyRelativePath(_:)), path: row.file.path) }

            if model.canModifyItems {
                addClipboardItem(menu, "Paste", "v", #selector(pasteClicked(_:)), row)
                menu.items.last?.isEnabled = canPaste
            }

            menu.addItem(.separator())
            if !row.file.isDirectory { add(menu, "Open", #selector(openClicked(_:)), path: row.file.path) }

            if model.canModifyItems, !isRoot {
                for (title, action) in [
                    ("Rename…", #selector(renameItem(_:))),
                    ("Duplicate…", #selector(duplicateItem(_:))),
                    ("Delete…", #selector(deleteItem(_:)))
                ] {
                    add(menu, title, action, path: row.file.path)
                    menu.items.last?.tag = row.file.isDirectory ? 1 : 0
                }
            }

            menu.addItem(.separator())
            let git = gitEntries?(row.file.path) ?? []
            if !git.isEmpty {
                let parent = NSMenuItem(title: "Git", action: nil, keyEquivalent: "")
                parent.image = WorkspaceIcon.image("arrow.triangle.branch", description: nil)
                let submenu = NSMenu(title: "Git")
                submenu.add(git)
                parent.submenu = submenu
                menu.addItem(parent)
                menu.addItem(.separator())
            }

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
        } else if model.canCreate {
            addNewSubmenu(to: menu, in: model.root)
            menu.addItem(.separator())
        }

        add(menu, "Show Excluded", #selector(toggleExcluded(_:)), checked: model.showExcluded)
        add(menu, "Show Ignored", #selector(toggleIgnored(_:)), checked: model.showIgnored)
        menu.items.last?.isEnabled = model.hasIgnoreInformation
        menu.items.last?.toolTip = model.hasIgnoreInformation ? nil : model.statusExplanation
        menu.autoenablesItems = false
        add(menu, "Refresh Files", #selector(refreshFiles(_:)))
    }

    /// New items go into a folder: the clicked one, or the folder a clicked file is in.
    private func addClipboardItem(_ menu: NSMenu, _ title: String, _ key: String, _ action: Selector, _ row: FileRow) {
        add(menu, title, action, path: row.file.path)
        menu.items.last?.keyEquivalent = key
        menu.items.last?.keyEquivalentModifierMask = .command
        menu.items.last?.isEnabled = true
    }

    // MARK: Cut, copy and paste

    /// What Cut put on the pasteboard, and the pasteboard's change count then: a Paste that finds the
    /// same count moves the items; any other copy of the pasteboard is a copy.
    private var cut: (paths: [String], changeCount: Int)?

    /// The item the clipboard commands act on: the clicked row, else the selected one.
    private var focusedItem: ProjectFile? {
        let row = outline.clickedRow >= 0 ? outline.clickedRow : outline.selectedRow
        guard let item = outline.item(atRow: row) as? FileRow, item.message == nil, item.file.path != model.root else {
            return nil
        }

        return item.file
    }

    var canCopy: Bool { focusedItem != nil }

    var canCut: Bool { model.canModifyItems && focusedItem != nil }

    /// Whether the pasteboard holds files and the tree may take them.
    var canPaste: Bool {
        model.canModifyItems && pasteboard.canReadObject(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        )
    }

    func copySelection() {
        guard let file = focusedItem else { return }

        write([file.path])
        cut = nil
    }

    func cutSelection() {
        guard canCut, let file = focusedItem else { return }

        write([file.path])
        cut = ([file.path], pasteboard.changeCount)
    }

    func pasteIntoSelection() {
        guard canPaste else { return }

        let urls = (pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]) ?? []
        guard !urls.isEmpty else { return }

        let destination = pasteDestination()
        let transfer: ProjectFiles.Transfer
        if let cut, cut.changeCount == pasteboard.changeCount {
            transfer = model.move(cut.paths, into: destination)
            if transfer.failure == nil { self.cut = nil }
        } else {
            transfer = model.copy(urls.map(\.path), into: destination)
        }

        if let failure = transfer.failure { showFailure(failure.message) }
    }

    /// Where Paste puts things: the folder of the focused item, or the project folder.
    private func pasteDestination() -> String {
        let row = outline.clickedRow >= 0 ? outline.clickedRow : outline.selectedRow
        guard let item = outline.item(atRow: row) as? FileRow, item.message == nil else { return model.root }

        return directory(of: item.file)
    }

    private func write(_ paths: [String]) {
        pasteboard.clearContents()
        pasteboard.writeObjects(paths.map { URL(fileURLWithPath: $0) as NSURL })
    }

    @objc private func cutClicked(_ item: NSMenuItem) { cutSelection() }

    @objc private func copyClicked(_ item: NSMenuItem) { copySelection() }

    @objc private func pasteClicked(_ item: NSMenuItem) { pasteIntoSelection() }

    // MARK: Drag and drop

    func installDragAndDrop() {
        outline.registerForDraggedTypes([.fileURL])
        outline.setDraggingSourceOperationMask([.move, .copy], forLocal: true)
        outline.setDraggingSourceOperationMask(.copy, forLocal: false)
        outline.draggingDestinationFeedbackStyle = .regular
        outline.clipboard = (
            copy: { [weak self] in self?.copySelection() },
            cut: { [weak self] in self?.cutSelection() },
            paste: { [weak self] in self?.pasteIntoSelection() },
            validate: { [weak self] action in
                switch action {
                case #selector(NSText.copy(_:)): self?.canCopy ?? false
                case #selector(NSText.cut(_:)): self?.canCut ?? false
                case #selector(NSText.paste(_:)): self?.canPaste ?? false
                default: true
                }
            }
        )
    }

    public func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let row = item as? FileRow, row.message == nil, row.file.path != model.root else { return nil }

        return URL(fileURLWithPath: row.file.path) as NSURL
    }

    public func outlineView(
        _ outlineView: NSOutlineView,
        validateDrop info: NSDraggingInfo,
        proposedItem item: Any?,
        proposedChildIndex index: Int
    ) -> NSDragOperation {
        let verdict = dropOperation(
            for: draggedURLs(info),
            onto: item,
            isInternal: info.draggingSource as? NSOutlineView === outline,
            copying: NSEvent.modifierFlags.contains(.option)
        )
        if let target = verdict.target {
            // Always drop *on* a folder, never between rows.
            outlineView.setDropItem(rows[target.path], dropChildIndex: NSOutlineViewDropOnItemIndex)
        }

        return verdict.operation
    }

    public func outlineView(
        _ outlineView: NSOutlineView,
        acceptDrop info: NSDraggingInfo,
        item: Any?,
        childIndex index: Int
    ) -> Bool {
        performDrop(
            of: draggedURLs(info),
            onto: item,
            isInternal: info.draggingSource as? NSOutlineView === outline,
            copying: NSEvent.modifierFlags.contains(.option)
        )
    }

    /// What dropping `urls` on `item` would do. Files dragged out of this tree are moved (copied with
    /// Option); files from elsewhere are copied. A folder never goes into itself.
    func dropOperation(
        for urls: [URL],
        onto item: Any?,
        isInternal: Bool,
        copying: Bool
    ) -> (operation: NSDragOperation, target: ProjectFile?) {
        guard model.canModifyItems, !urls.isEmpty, let target = dropFolder(for: item) else { return ([], nil) }

        for url in urls where target.path == url.path || target.path.hasPrefix(url.path + "/") { return ([], nil) }

        return (isInternal && !copying ? .move : .copy, target)
    }

    @discardableResult
    func performDrop(of urls: [URL], onto item: Any?, isInternal: Bool, copying: Bool) -> Bool {
        let verdict = dropOperation(for: urls, onto: item, isInternal: isInternal, copying: copying)
        guard let target = verdict.target else { return false }

        let paths = urls.map(\.path)
        let transfer = verdict.operation == .move
            ? model.move(paths, into: target.path)
            : model.copy(paths, into: target.path)
        if let failure = transfer.failure { showFailure(failure.message) }

        return !transfer.done.isEmpty
    }

    /// The folder a drop lands in: the folder under the pointer, the folder of a file under it, or
    /// the project folder.
    private func dropFolder(for item: Any?) -> ProjectFile? {
        guard let row = item as? FileRow else { return rows[model.root]?.file }

        guard row.message == nil else { return nil }

        return row.file.isDirectory ? row.file : rows[(row.file.path as NSString).deletingLastPathComponent]?.file
    }

    private func draggedURLs(_ info: NSDraggingInfo) -> [URL] {
        (info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]) ?? []
    }

    private func directory(of file: ProjectFile) -> String {
        file.isDirectory ? file.path : (file.path as NSString).deletingLastPathComponent
    }

    private func addNewSubmenu(to menu: NSMenu, in directory: String) {
        let parent = NSMenuItem(title: "New", action: nil, keyEquivalent: "")
        parent.image = WorkspaceIcon.image("tabler:plus", description: nil)
        let submenu = NSMenu(title: "New")
        submenu.autoenablesItems = false
        let entries: [(String, String, Selector)] = [
            ("Swift File", "swift", #selector(newSwiftFile(_:))),
            ("File", "doc.text", #selector(newFile(_:))),
            ("Directory", "folder", #selector(newFolder(_:)))
        ]
        for (title, icon, action) in entries {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = directory
            item.image = WorkspaceIcon.image(icon, description: nil)
            submenu.addItem(item)
        }

        parent.submenu = submenu
        menu.addItem(parent)
        menu.addItem(.separator())
    }

    @objc private func newSwiftFile(_ item: NSMenuItem) { ask(for: .swiftFile, in: item.representedObject as? String) }

    @objc private func newFile(_ item: NSMenuItem) { ask(for: .file, in: item.representedObject as? String) }

    @objc private func newFolder(_ item: NSMenuItem) { ask(for: .folder, in: item.representedObject as? String) }

    private var namePrompt: NamePromptPanel?

    private func ask(for kind: NewEntryKind, in directory: String?) {
        guard let directory else { return }

        let prompt: NamePrompt = switch kind {
        case .swiftFile: NamePrompt(title: "New Swift File", icon: "swift")
        case .file: NamePrompt(title: "New File", icon: "doc.text")
        case .folder: NamePrompt(title: "New Directory", icon: "folder")
        }
        askForName(prompt) { [weak self] name in self?.create(kind, named: name, in: directory) }
    }

    /// Makes the item and opens it if it is a file. The answer is nil, or why it could not be made.
    func create(_ kind: NewEntryKind, named name: String, in directory: String) -> String? {
        do {
            let path = try model.create(kind, named: name, in: directory)
            if kind != .folder { openFile?(path) }

            return nil
        } catch let error as NewEntryError {
            return error.message
        } catch {
            return error.localizedDescription
        }
    }

    @objc private func renameItem(_ item: NSMenuItem) {
        guard let path = item.representedObject as? String else { return }

        let name = (path as NSString).lastPathComponent
        let folder = item.tag == 1
        let prompt = NamePrompt(
            title: "Rename \(folder ? "Folder" : "File")",
            icon: folder ? "folder" : "doc.text",
            initialText: name,
            selectsBaseName: !folder
        )
        askForName(prompt) { [weak self] typed in
            guard let self else { return nil }

            return run { _ = try self.model.rename(path, to: typed) }
        }
    }

    @objc private func duplicateItem(_ item: NSMenuItem) {
        guard let path = item.representedObject as? String else { return }

        let name = (path as NSString).lastPathComponent
        let parent = (path as NSString).deletingLastPathComponent
        let suggestion = ItemName.copyName(of: name) { FileManager.default.fileExists(atPath: parent + "/" + $0) }
        let folder = item.tag == 1
        let prompt = NamePrompt(
            title: "Duplicate \(folder ? "Folder" : "File")",
            icon: folder ? "folder" : "doc.text",
            initialText: suggestion,
            selectsBaseName: !folder
        )
        askForName(prompt) { [weak self] typed in
            guard let self else { return nil }

            return run {
                let copy = try self.model.duplicate(path, as: typed)
                if !folder { self.openFile?(copy) }
            }
        }
    }

    @objc private func deleteItem(_ item: NSMenuItem) {
        guard let path = item.representedObject as? String else { return }

        let name = (path as NSString).lastPathComponent
        let unsaved = model.unsavedCount(under: path)
        var message = item.tag == 1
            ? "The folder and everything in it will be moved to the Trash."
            : "The file will be moved to the Trash."
        if unsaved > 0 {
            message += unsaved == 1
                ? " One open file has changes that are not saved; they will be lost."
                : " \(unsaved) open files have changes that are not saved; they will be lost."
        }

        let proceed: (Bool) -> Void = { [weak self] confirmed in
            guard confirmed, let self, let failure = run({ try self.model.trash(path) }) else { return }

            showFailure(failure)
        }
        let title = "Delete “\(name)”?"
        if let confirmTrash { return confirmTrash(title, message, proceed) }

        presentConfirmation(title: title, message: message, completion: proceed)
    }

    /// Runs a change of the tree: nil if it worked, otherwise why it did not.
    private func run(_ change: () throws -> Void) -> String? {
        do {
            try change()

            return nil
        } catch let error as NewEntryError {
            return error.message
        } catch {
            return error.localizedDescription
        }
    }

    private func askForName(_ prompt: NamePrompt, submit: @escaping (String) -> String?) {
        if let promptForName { return promptForName(prompt, submit) }

        namePrompt?.cancel()
        let panel = NamePromptPanel(prompt: prompt, over: view.window, submit: submit) { [weak self] in
            self?.namePrompt = nil
        }
        namePrompt = panel
        panel.show()
    }

    private func presentConfirmation(title: String, message: String, completion: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard let window = view.window else { return completion(alert.runModal() == .alertFirstButtonReturn) }

        alert.beginSheetModal(for: window) { completion($0 == .alertFirstButtonReturn) }
    }

    /// Reports why something could not be done. Replaced in tests; the default is a sheet.
    public var reportFailure: ((String) -> Void)?

    private func showFailure(_ message: String) {
        if let reportFailure { return reportFailure(message) }

        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        if let window = view.window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    @objc private func openClicked(_ item: NSMenuItem) {
        if let path = item.representedObject as? String { openFile?(path) }
    }

    @objc private func copyPath(_ item: NSMenuItem) {
        if let path = item.representedObject as? String { copy(path) }
    }

    @objc private func copyRelativePath(_ item: NSMenuItem) {
        guard let path = item.representedObject as? String, path.hasPrefix(model.root + "/") else { return }

        copy(String(path.dropFirst(model.root.count + 1)))
    }

    private func copy(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
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
    /// The responder-chain commands Cut, Copy and Paste, as the view controller answers them.
    var clipboard: (
        copy: () -> Void,
        cut: () -> Void,
        paste: () -> Void,
        validate: (Selector) -> Bool
    )?

    @objc func copy(_ sender: Any?) { clipboard?.copy() }

    @objc func cut(_ sender: Any?) { clipboard?.cut() }

    @objc func paste(_ sender: Any?) { clipboard?.paste() }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        guard let action = item.action, [
            #selector(NSText.copy(_:)),
            #selector(NSText.cut(_:)),
            #selector(NSText.paste(_:))
        ].contains(action) else {
            return super.validateUserInterfaceItem(item)
        }

        return clipboard?.validate(action) ?? false
    }

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
