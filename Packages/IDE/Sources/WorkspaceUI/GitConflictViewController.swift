import AppKit
import IDEApplication

/// Read-only Git stages plus a host-injected native result editor. It owns no document or process.
@MainActor
public final class GitConflictViewController: NSViewController {
    public let workspace: GitWorkspace
    public let conflict: GitConflict
    public var group: GitConflictGroup? { didSet { if isViewLoaded { renderGroup() } } }
    public var resolveGroup: ((GitConflictGroup, Int) -> Void)?
    private let groupLabel = NSTextField(wrappingLabelWithString: "")
    private var groupButtons: [NSButton] = []
    private let groupRow = NSStackView()
    public var takeTextSide: ((GitConflictSide) -> Void)?
    public var takeRegion: ((GitConflictRegion, GitConflictRegionChoice) -> Void)?
    public var selectRegion: ((GitConflictRegion) -> Void)?
    public private(set) var sourcePreviews: [Int: NSTextView] = [:]
    public let linkedScroll = NSButton(checkboxWithTitle: "Link relative scroll positions", target: nil, action: nil)
    private var sourceScrolls: [Int: NSScrollView] = [:]
    private weak var resultScroll: NSScrollView?
    private var synchronizingScroll = false
    public let region = NSPopUpButton()
    public let regionBase = NSButton(title: "Base", target: nil, action: nil)
    public let regionOurs = NSButton(title: "Ours", target: nil, action: nil)
    public let regionTheirs = NSButton(title: "Theirs", target: nil, action: nil)
    private var regions: [GitConflictRegion] = []
    public var restoreStage: ((Int) -> Void)?
    public var resolveWorking: (() -> Void)?
    public var resolveAllowingLiteralMarkers: (() -> Void)?
    public let literalMarkers = NSButton(
        checkboxWithTitle: "Allow marker-looking literal text",
        target: nil,
        action: nil
    )
    public var resolveDeleted: (() -> Void)?
    public var resolveIndexStage: ((Int) -> Void)?
    public var resolveIndexDeleted: (() -> Void)?
    public let indexBase = NSButton(title: "Index: Base…", target: nil, action: nil)
    public let indexOurs = NSButton(title: "Ours…", target: nil, action: nil)
    public let indexTheirs = NSButton(title: "Theirs…", target: nil, action: nil)
    public let indexDeleted = NSButton(title: "Deleted…", target: nil, action: nil)
    public var reopen: (() -> Void)?
    public var openResult: (() -> Void)?
    public var closePreview: (() -> Void)?
    public var canEditResult: (() -> Bool)?
    public let resultHost = NSView()
    public let mark = NSButton(title: "Save and mark resolved", target: nil, action: nil)
    private let remove = NSButton(title: "Resolve as deleted…", target: nil, action: nil)
    private let resultLabel = NSTextField(labelWithString: "")
    private let status = NSTextField(wrappingLabelWithString: "")
    private var buttons: [NSButton] = []
    private var subscription: UUID?
    private var installedConstraints: [NSLayoutConstraint] = []
    private var installedEditor: NSView?

    public init(workspace: GitWorkspace, conflict: GitConflict) {
        self.workspace = workspace
        self.conflict = conflict
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func loadView() {
        view = GitContextBackground()
        let heading = NSTextField(labelWithString: "Resolve · " + conflict.path)
        heading.font = .systemFont(ofSize: 14, weight: .semibold)
        let reload = NSButton(title: "Reload stages", target: self, action: #selector(reopenContext(_:)))
        let close = NSButton(title: "Close preview", target: self, action: #selector(closeContext(_:)))
        let panes = GitStageSplitView()
        panes.isVertical = true
        panes.dividerStyle = .thin
        for (stage, title) in [(1, "Base · common ancestor"), (
            2,
            conflict.integration?.kind == .rebase
                ? "Ours · rebased upstream"
                : "Ours · current side"
        ), (
            3,
            conflict.integration?.kind == .rebase
                ? "Theirs · commit being replayed"
                : "Theirs · incoming side"
        )] {
            let side = conflict.sides.first { $0.stage == stage }
            let text = NSTextView(usingTextLayoutManager: true)
            sourcePreviews[stage] = text
            text.frame = NSRect(x: 0, y: 0, width: 180, height: 65)
            text.isEditable = false
            text.isRichText = false
            text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            text.isVerticallyResizable = true
            text.autoresizingMask = [.width]
            text.textContainer?.widthTracksTextView = true
            text.string = side.map {
                $0.previewText ?? """
                Binary, unsupported or oversized · \($0.bytes) bytes · mode \($0.mode) · index-only choice \
                available
                """
            }
                ?? "Absent in this stage (addition/deletion)"
            text.setAccessibilityLabel(title + ": " + conflict.path)
            let scroll = NSScrollView.nonElastic()
            scroll.documentView = text
            sourceScrolls[stage] = scroll
            scroll.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(scrollChanged(_:)),
                name: NSView.boundsDidChangeNotification,
                object: scroll.contentView
            )
            scroll.hasVerticalScroller = true
            let preferredHeight = scroll.heightAnchor.constraint(equalToConstant: 150)
            preferredHeight.priority = .defaultHigh
            preferredHeight.isActive = true
            let use = NSButton(
                title: "Use " + (stage == 1 ? "Base" : stage == 2 ? "Ours" : "Theirs"),
                target: self,
                action: #selector(useSide(_:))
            )
            use.tag = stage
            use.isEnabled = side != nil
            buttons.append(use)
            let label = NSTextField(labelWithString: title + (side?.previewText != side?.text
                    ? " · shortened preview"
                    : ""))
            label.font = .systemFont(ofSize: 11)
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            label.toolTip = title + (side.map { "\n" + $0.oid + " · mode " + $0.mode } ?? "\nAbsent stage")
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let pane = gitStack([label, scroll, use])
            pane.widthAnchor.constraint(greaterThanOrEqualToConstant: 70).isActive = true
            panes.addArrangedSubview(pane)
        }
        let preferredPaneHeight = panes.heightAnchor.constraint(equalToConstant: 220)
        preferredPaneHeight.priority = .defaultHigh
        preferredPaneHeight.isActive = true
        panes.heightAnchor.constraint(greaterThanOrEqualToConstant: 110).isActive = true
        mark.target = self
        region.setAccessibilityLabel("Conflict region in result")
        for (button, stage) in [(indexBase, 1), (indexOurs, 2), (indexTheirs, 3)] {
            button.tag = stage
            button.target = self
            button.action = #selector(indexStageSelected(_:))
            button.toolTip = "Resolve the index using the frozen stage; working files and editor text stay unchanged."
        }
        indexDeleted.target = self
        indexDeleted.action = #selector(indexDeleteSelected(_:))
        indexDeleted.toolTip = "Resolve this index path as deleted, keeping every working directory/file byte."
        region.target = self
        region.action = #selector(regionChanged(_:))
        for (button, tag) in [(regionBase, 1), (regionOurs, 2), (regionTheirs, 3)] {
            button.tag = tag
            button.target = self
            button.action = #selector(useRegion(_:))
        }
        mark.action = #selector(markWorking(_:))
        remove.target = self
        remove.action = #selector(deleteResult(_:))
        status.font = .systemFont(ofSize: 11)
        status.maximumNumberOfLines = 2
        let open = NSButton(title: "Open result", target: self, action: #selector(openWorking(_:)))
        let result = resultLabel
        result.font = .systemFont(ofSize: 11, weight: .semibold)
        groupRow.orientation = .horizontal
        groupRow.spacing = 8
        for (stage, title) in [(1, "Related paths: Base…"), (2, "Ours…"), (3, "Theirs…")] {
            let button = NSButton(title: title, target: self, action: #selector(resolveRelated(_:)))
            button.tag = stage
            groupButtons.append(button)
            groupRow.addArrangedSubview(button)
        }
        groupLabel.font = .systemFont(ofSize: 11)
        let stack = gitStack([
            gitStack([heading, NSView(), reload, close], vertical: false),
            panes,
            gitStack([region, regionBase, regionOurs, regionTheirs], vertical: false),
            linkedScroll,
            literalMarkers,
            gitStack([indexBase, indexOurs, indexTheirs, indexDeleted], vertical: false),
            groupLabel,
            groupRow,
            status,
            gitStack([mark, remove, open], vertical: false),
            result,
            resultHost
        ])
        stack.spacing = 6
        gitPin(stack, to: view, inset: 8)
        resultHost.heightAnchor.constraint(greaterThanOrEqualToConstant: 80).isActive = true
        subscription = workspace.subscribe { [weak self] in self?.render() }
        render()
        renderGroup()
    }

    @objc private func resolveRelated(_ sender: NSButton) {
        guard sender.isEnabled, let group else { return }

        resolveGroup?(group, sender.tag)
    }

    private func renderGroup() {
        groupLabel.isHidden = group == nil
        groupRow.isHidden = group == nil
        groupLabel.stringValue = group.map { "Native rename relationships: " + $0.paths.joined(separator: " · ")
            + ". Resolve the reviewed group in the index; all working copies remain."
        } ?? ""
        for button in groupButtons {
            button.isEnabled = workspace.canMutate && group != nil
                && workspace.snapshot?.integration == group?.integration
                && group?.sides.contains(where: { $0.stage == button.tag }) == true
        }
    }

    public func installEditor(_ editor: NSView?) {
        _ = view
        NSLayoutConstraint.deactivate(installedConstraints)
        installedConstraints = []
        installedEditor?.removeFromSuperview()
        installedEditor = editor
        guard let editor else {
            render()

            return
        }

        editor.translatesAutoresizingMaskIntoConstraints = false
        resultHost.addSubview(editor)
        installedConstraints = [
            editor.topAnchor.constraint(equalTo: resultHost.topAnchor),
            editor.bottomAnchor.constraint(equalTo: resultHost.bottomAnchor),
            editor.leadingAnchor.constraint(equalTo: resultHost.leadingAnchor),
            editor.trailingAnchor.constraint(equalTo: resultHost.trailingAnchor)
        ]
        NSLayoutConstraint.activate(installedConstraints)
        render()
    }

    public func presentRegions(_ values: [GitConflictRegion]) {
        _ = view
        let selected = region.indexOfSelectedItem
        regions = values
        region.removeAllItems()
        region.addItems(withTitles: values.enumerated().map { "Region \($0.offset + 1)" })
        if !values.isEmpty { region.selectItem(at: min(max(0, selected), values.count - 1)) }
        regionChanged(nil)
    }

    @objc public func regionChanged(_ sender: Any?) {
        let selected = regions.indices.contains(region.indexOfSelectedItem) ? regions[region.indexOfSelectedItem] : nil
        let unresolved = workspace.snapshot?.repository == conflict.repository && workspace.snapshot?.changes
            .contains { $0.path == conflict.path && $0.decoration.isConflict } == true
        let enabled = workspace.canMutate && unresolved && canEditResult?() == true && selected != nil
        regionBase.isEnabled = enabled && selected?.base != nil
        regionOurs.isEnabled = enabled
        regionTheirs.isEnabled = enabled
        if sender != nil, let selected { selectRegion?(selected) }
    }

    @objc public func useRegion(_ sender: NSButton) {
        guard sender.isEnabled, regions.indices.contains(region.indexOfSelectedItem) else { return }

        takeRegion?(regions[region.indexOfSelectedItem], sender.tag == 1 ? .base : sender.tag == 2 ? .ours : .theirs)
    }

    public func linkResultScroll(_ scroll: NSScrollView?) {
        if let resultScroll {
            NotificationCenter.default.removeObserver(
                self,
                name: NSView.boundsDidChangeNotification,
                object: resultScroll.contentView
            )
        }

        resultScroll = scroll
        if let scroll {
            scroll.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(scrollChanged(_:)),
                name: NSView.boundsDidChangeNotification,
                object: scroll.contentView
            )
        }
    }

    @objc private func scrollChanged(_ notification: Notification) {
        guard linkedScroll.state == .on, !synchronizingScroll, let clip = notification.object as? NSClipView,
              let source = clip.superview as? NSScrollView else { return }

        let total = max(0, (source.documentView?.bounds.height ?? 0) - clip.bounds.height)
        guard total > 0 else { return }

        let fraction = min(1, max(0, clip.bounds.minY / total))
        synchronizingScroll = true
        defer { synchronizingScroll = false }
        for destination in Array(sourceScrolls.values) + [resultScroll].compactMap({ $0 })
            where destination !== source {
            let height = max(0, (destination.documentView?.bounds.height ?? 0) - destination.contentView.bounds.height)
            let point = NSPoint(x: destination.contentView.bounds.minX, y: height * fraction)
            if abs(point.y - destination.contentView.bounds.minY) > 0.5 {
                destination.contentView.scroll(to: point)
                destination.reflectScrolledClipView(destination.contentView)
            }
        }
    }

    @objc func useSide(_ sender: NSButton) {
        guard sender.isEnabled, let side = conflict.sides.first(where: { $0.stage == sender.tag }) else { return }

        if side.mode == "160000" || side.bytes > 8_000_000 || (installedEditor != nil && side.mode == "120000") {
            resolveIndexStage?(sender.tag)
        }
        else if installedEditor != nil, side.text != nil, canEditResult?() == true { takeTextSide?(side) }
        else { restoreStage?(sender.tag) }
    }

    @objc public func indexStageSelected(_ sender: NSButton) { if sender.isEnabled { resolveIndexStage?(sender.tag) } }

    @objc public func indexDeleteSelected(_ sender: Any?) { if indexDeleted.isEnabled { resolveIndexDeleted?() } }

    @objc func markWorking(_ sender: Any?) {
        guard mark.isEnabled else { return }

        if literalMarkers.state == .on { resolveAllowingLiteralMarkers?() } else { resolveWorking?() }
    }

    @objc private func deleteResult(_ sender: Any?) { if remove.isEnabled { resolveDeleted?() } }

    @objc private func reopenContext(_ sender: Any?) { if workspace.canMutate { reopen?() } }

    @objc private func openWorking(_ sender: Any?) { openResult?() }

    @objc private func closeContext(_ sender: Any?) { closePreview?() }

    private func render() {
        renderGroup()
        regionChanged(nil)
        resultLabel.stringValue = installedEditor != nil
            ? "Result · native editor (not staged until marked resolved)"
            : conflict.workingText != nil
                ? "Result · Open result in its owner window or edit externally"
                : "Result · absent/binary; restore a stage or edit externally, then Reload stages"
        let unresolved = workspace.snapshot?.repository == conflict.repository && workspace.snapshot?.changes
            .contains { $0.path == conflict.path && $0.decoration.isConflict } == true
        let enabled = workspace.canMutate && unresolved && conflict.supportsResolution
        mark.isEnabled = enabled && conflict.workingExists && ![.directory, .submodule, .oversized]
            .contains(conflict.workingKind)
        remove.isEnabled = enabled && ![.directory, .submodule, .oversized].contains(conflict.workingKind)
        literalMarkers.isHidden = conflict.workingKind != .file
        for button in [indexBase, indexOurs, indexTheirs] {
            button.isEnabled = enabled && conflict.sides.contains { $0.stage == button.tag }
        }
        indexDeleted.isEnabled = enabled
        for button in buttons {
            let side = conflict.sides.first { $0.stage == button.tag }
            let editable = installedEditor == nil || side?.text == nil || canEditResult?() == true
            button.isEnabled = enabled && side != nil && editable && (side?.bytes ?? 0) <= 8_000_000
            button.toolTip = installedEditor != nil && side?.text != nil
                ? "Replace the native editor result as one undoable edit; does not stage"
                : "Restore stage blob on disk after explicit confirmation; does not mark resolved"
        }
        status.stringValue = !conflict.supportsResolution
            ? "Unsupported index mode."
            : unresolved
                ? """
                Review all changes before marking. Save stages only this path; remaining conflict markers are \
                refused. Missing sides are not empty files. Reopen after external index/operation changes.
                """
                : "This path is no longer unmerged. The preview is retained; close it to keep editing the document."
        if workspace.operationState.isBusy { status.stringValue = workspace.operationState.explanation }
        else if case .failed(let error) = workspace.operationState { status.stringValue = error }
    }

    public func disconnect() {
        NotificationCenter.default.removeObserver(self)
        resultScroll = nil
        if let subscription { workspace.unsubscribe(subscription) }
        subscription = nil
        installEditor(nil)
    }
}

@MainActor final class GitContextBackground: NSView {
    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            dirtyRect.fill()
        }
    }
}

@MainActor private final class GitStageSplitView: NSSplitView, NSSplitViewDelegate {
    private var initializedWidths = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
        guard !subviews.isEmpty else { return }

        let available = max(0, bounds.width - CGFloat(subviews.count - 1) * dividerThickness)
        guard available > 0 else { return }

        let previous = subviews.map { $0.frame.width }, total = previous.reduce(0, +)
        let weights = initializedWidths && total > 0
            ? previous.map { $0 / total }
            : Array(repeating: 1 / CGFloat(subviews.count), count: subviews.count)
        initializedWidths = true
        var offset: CGFloat = 0
        for (index, child) in subviews.enumerated() {
            child.frame = NSRect(x: offset, y: 0, width: available * weights[index], height: bounds.height)
            offset += child.frame.width + dividerThickness
        }
    }
}
