import AppKit
import IDEApplication
import IDEDomain

public struct DocumentTabPresentation: Equatable {
    public let id: DocumentID
    public let name: String
    public let path: String
    public let decoration: FileDecoration

    public init(id: DocumentID, name: String, path: String, decoration: FileDecoration = .init()) {
        self.id = id
        self.name = name
        self.path = path
        self.decoration = decoration
    }
}

/// Reusable central content. Documents and tools are supplied by the host application.
@MainActor
public final class EditorAreaViewController: NSViewController {
    public let tabs = DocumentTabBarViewController()
    public private(set) var active: NSViewController?
    public private(set) var focusTarget: NSView?
    private let content = NSView()
    private let empty =
        NSTextField(
            wrappingLabelWithString: """
            Open a file from Files to begin editing.\nDouble-click a file, or select it and press Return.
            """
        )

    public init() { super.init(nibName: nil, bundle: nil) }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func loadView() {
        view = NSView()
        view.clipsToBounds = true
        content.clipsToBounds = true
        addChild(tabs)
        for subview in [tabs.view, content] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        empty.alignment = .center
        empty.textColor = .secondaryLabelColor
        empty.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(empty)
        NSLayoutConstraint.activate([
            tabs.view.topAnchor.constraint(equalTo: view.topAnchor),
            tabs.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tabs.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tabs.view.heightAnchor.constraint(equalToConstant: 42),
            content.topAnchor.constraint(equalTo: tabs.view.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            empty.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            empty.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor, constant: -40)
        ])
    }

    public func show(_ controller: NSViewController?, focusTarget: NSView? = nil) {
        _ = view
        self.focusTarget = focusTarget
        guard active !== controller else { return }

        active?.view.removeFromSuperview()
        active?.removeFromParent()
        active = controller
        empty.isHidden = controller != nil
        guard let controller else { return }

        addChild(controller)
        let editor = controller.view
        editor.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(editor)
        NSLayoutConstraint.activate([
            editor.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            editor.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            editor.topAnchor.constraint(equalTo: content.topAnchor),
            editor.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
    }
}

@MainActor
public final class DocumentTabBarViewController: NSViewController, NSCollectionViewDataSource,
    NSCollectionViewDelegateFlowLayout {
    public let collection = NSCollectionView()
    public var onSelect: ((DocumentID) -> Void)?
    public var onClose: ((DocumentID) -> Void)?
    public var onMove: ((DocumentID, Int) -> Void)?
    public private(set) var items: [DocumentTabPresentation] = []
    public private(set) var selected: DocumentID?
    private let scroll = NSScrollView.nonElastic()
    private let owner = UUID().uuidString
    private let dragType = NSPasteboard.PasteboardType("org.swiftide.document-tab")
    private var renderPending = false
    private var lastSelection: DocumentID?
    private var lastSelectionIndex: Int?
    private var displayedItems: [DocumentTabPresentation] = []

    public init() { super.init(nibName: nil, bundle: nil) }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func loadView() {
        view = NSView()
        view.clipsToBounds = true
        let layout = NSCollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.minimumInteritemSpacing = 4
        layout.minimumLineSpacing = 4
        layout.sectionInset = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        collection.collectionViewLayout = layout
        collection.dataSource = self
        collection.delegate = self
        collection.isSelectable = true
        collection.allowsMultipleSelection = false
        collection.backgroundColors = [.windowBackgroundColor]
        collection.register(DocumentTabCell.self, forItemWithIdentifier: .init("DocumentTab"))
        collection.registerForDraggedTypes([dragType])
        collection.setDraggingSourceOperationMask(.move, forLocal: true)
        collection.setDraggingSourceOperationMask([], forLocal: false)
        scroll.documentView = collection
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        scheduleRender()
    }

    public override func viewDidLayout() {
        super.viewDidLayout()
        sizeCollection()
    }

    private func sizeCollection() {
        guard isViewLoaded, let layout = collection.collectionViewLayout else { return }

        let widths = displayedItems.indices.map { index in
            self.collectionView(collection, layout: layout, sizeForItemAt: IndexPath(item: index, section: 0)).width
        }
        let width = widths.reduce(16, +) + CGFloat(max(0, widths.count - 1)) * 4
        let size = NSSize(
            width: max(scroll.contentView.bounds.width, width),
            height: max(42, scroll.contentView.bounds.height)
        )
        if collection.frame.size != size { collection.setFrameSize(size) }
    }

    public func present(_ items: [DocumentTabPresentation], selected: DocumentID?) {
        guard self.items != items || self.selected != selected else { return }

        self.items = items
        self.selected = selected
        if isViewLoaded { scheduleRender() }
    }

    // AppKit may still be selecting or accepting a drag when the caller publishes new tab state.
    private func scheduleRender() {
        guard !renderPending else { return }

        renderPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            renderPending = false
            displayedItems = items
            sizeCollection()
            collection.reloadData()
            collection.layoutSubtreeIfNeeded()
            if let selected, let index = items.firstIndex(where: { $0.id == selected }) {
                let path = IndexPath(item: index, section: 0)
                collection.selectionIndexPaths = [path]
                defer { lastSelectionIndex = index }
                if lastSelection != selected || lastSelectionIndex != index { revealTab(at: path) }
            } else {
                collection.selectionIndexPaths = []
                lastSelectionIndex = nil
            }

            lastSelection = selected
        }
    }

    private func revealTab(at path: IndexPath) {
        guard let frame = collection.collectionViewLayout?.layoutAttributesForItem(at: path)?.frame else { return }

        let clip = scroll.contentView
        let visible = clip.bounds
        var x = visible.minX
        if frame.minX < visible.minX { x = frame.minX - 6 }
        if frame.maxX > visible.maxX { x = frame.maxX - visible.width + 6 }
        x = min(max(0, collection.bounds.width - visible.width), max(0, x))
        clip.scroll(to: NSPoint(x: x, y: 0))
        scroll.reflectScrolledClipView(clip)
    }

    public func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        displayedItems.count
    }
    public func collectionView(
        _ collectionView: NSCollectionView,
        itemForRepresentedObjectAt indexPath: IndexPath
    ) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: .init("DocumentTab"), for: indexPath)
        guard let cell = item as? DocumentTabCell, displayedItems.indices.contains(indexPath.item) else { return item }

        let tab = displayedItems[indexPath.item]
        cell.present(tab, selected: tab.id == selected)
        cell.close = { [weak self] in self?.onClose?(tab.id) }

        return cell
    }
    public func collectionView(
        _ collectionView: NSCollectionView,
        layout collectionViewLayout: NSCollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> NSSize {
        guard displayedItems.indices.contains(indexPath.item) else { return NSSize(width: 100, height: 30) }

        let item = displayedItems[indexPath.item]
        let title = item.name + (item.decoration.badges.isEmpty ? "" : "  " + item.decoration.badges)
        let width = (title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width

        return NSSize(width: min(280, max(120, width + 70)), height: 30)
    }
    public func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard let path = indexPaths.first, displayedItems.indices.contains(path.item) else { return }

        onSelect?(displayedItems[path.item].id)
    }
    public func collectionView(
        _ collectionView: NSCollectionView,
        pasteboardWriterForItemAt indexPath: IndexPath
    ) -> (any NSPasteboardWriting)? {
        guard displayedItems.indices.contains(indexPath.item) else { return nil }

        let writer = NSPasteboardItem()
        writer.setString(owner + ":" + displayedItems[indexPath.item].id.rawValue.uuidString, forType: dragType)

        return writer
    }
    public func collectionView(
        _ collectionView: NSCollectionView,
        validateDrop draggingInfo: any NSDraggingInfo,
        proposedIndexPath proposedDropIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
        dropOperation proposedDropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>
    ) -> NSDragOperation {
        guard draggingInfo.draggingSource as? NSCollectionView === collection,
              draggedID(from: draggingInfo.draggingPasteboard) != nil else {
            return []
        }

        proposedDropOperation.pointee = .before

        return .move
    }
    public func collectionView(
        _ collectionView: NSCollectionView,
        acceptDrop draggingInfo: any NSDraggingInfo,
        indexPath: IndexPath,
        dropOperation: NSCollectionView.DropOperation
    ) -> Bool {
        guard dropOperation == .before else { return false }

        return moveTab(
            from: draggingInfo.draggingSource as? NSCollectionView,
            pasteboard: draggingInfo.draggingPasteboard,
            to: indexPath.item
        )
    }
    func moveTab(from source: NSCollectionView?, pasteboard: NSPasteboard, to index: Int) -> Bool {
        guard source === collection, let id = draggedID(from: pasteboard),
              (0...displayedItems.count).contains(index) else {
            return false
        }

        onMove?(id, index)

        return true
    }
    private func draggedID(from pasteboard: NSPasteboard) -> DocumentID? {
        guard let payload = pasteboard.string(forType: dragType), payload.hasPrefix(owner + ":"),
              let uuid = UUID(uuidString: String(payload.dropFirst(owner.count + 1))) else { return nil }

        let id = DocumentID(rawValue: uuid)

        return displayedItems.contains(where: { $0.id == id }) ? id : nil
    }
}

@MainActor
private final class DocumentTabCell: NSCollectionViewItem {
    private let surface = TabSurface()
    private let label = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    private let closeButton = NSButton()
    var close: (() -> Void)?

    override func loadView() {
        view = surface
        surface.onHover = { [weak self] hovering in
            guard let self else { return }

            hovered = hovering
            showSelection(active)
        }
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
        closeButton.image = WorkspaceIcon.image("xmark", description: "Close tab")
        closeButton.isBordered = false
        closeButton.target = self
        closeButton.action = #selector(closeTab(_:))
        closeButton.widthAnchor.constraint(equalToConstant: 20).isActive = true
        let stack = NSStackView(views: [icon, label, closeButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -4),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }
    override var isSelected: Bool { didSet { showSelection(isSelected) } }
    private var hovered = false
    private var active = false
    /// The active tab always has a close button; another one shows it while the pointer is over the tab.
    private func showSelection(_ selected: Bool) {
        active = selected
        surface.selected = selected
        surface.hovered = hovered
        surface.needsDisplay = true
        closeButton.isHidden = !(selected || hovered)
    }
    override func prepareForReuse() {
        super.prepareForReuse()
        hovered = false
    }
    func present(_ item: DocumentTabPresentation, selected: Bool) {
        _ = view
        label.stringValue = item.name + (item.decoration.badges.isEmpty ? "" : "  " + item.decoration.badges)
        label.textColor = item.decoration.tone.colour
        icon.image = WorkspaceIcon.image(
            (item.name as NSString).pathExtension == "swift" ? "swift" : "doc.text",
            description: nil
        )
        icon.contentTintColor = .secondaryLabelColor
        view.toolTip = [item.path, item.decoration.explanation].filter { !$0.isEmpty }.joined(separator: "\n")
        view.setAccessibilityLabel(label.stringValue)
        closeButton.setAccessibilityLabel("Close " + item.name)
        showSelection(selected)
    }
    @objc private func closeTab(_ sender: Any?) { close?() }
}

@MainActor
private final class TabSurface: NSView {
    var selected = false
    var hovered = false
    var onHover: ((Bool) -> Void)?
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }

        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }

    override func mouseExited(with event: NSEvent) { onHover?(false) }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
        if !selected {
            // The pointer is over an inactive tab: a faint pill, in the text colour of the appearance.
            guard hovered else { return }

            NSColor.labelColor.withAlphaComponent(0.08).setFill()
            path.fill()

            return
        }

        NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
        path.fill()
        NSColor.controlAccentColor.withAlphaComponent(0.5).setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}
