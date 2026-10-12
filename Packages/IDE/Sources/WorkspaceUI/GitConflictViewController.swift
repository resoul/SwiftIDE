import AppKit
import IDEApplication

/// Read-only Git stages plus a host-injected native result editor. It owns no document or process.
@MainActor
public final class GitConflictViewController: NSViewController {
    public let workspace: GitWorkspace
    public let conflict: GitConflict
    public var takeTextSide: ((GitConflictSide) -> Void)?
    public var restoreStage: ((Int) -> Void)?
    public var resolveWorking: (() -> Void)?
    public var resolveDeleted: (() -> Void)?
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

    public init(workspace: GitWorkspace, conflict: GitConflict) { self.workspace = workspace; self.conflict = conflict; super.init(nibName: nil, bundle: nil) }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func loadView() {
        view = GitContextBackground()
        let heading = NSTextField(labelWithString: "Resolve · " + conflict.path)
        heading.font = .systemFont(ofSize: 14, weight: .semibold)
        let reload = NSButton(title: "Reload stages", target: self, action: #selector(reopenContext(_:)))
        let close = NSButton(title: "Close preview", target: self, action: #selector(closeContext(_:)))
        let panes = GitStageSplitView(); panes.isVertical = true; panes.dividerStyle = .thin
        for (stage, title) in [(1, "Base · common ancestor"), (2, conflict.integration?.kind == .rebase ? "Ours · rebased upstream" : "Ours · current side"), (3, conflict.integration?.kind == .rebase ? "Theirs · commit being replayed" : "Theirs · incoming side")] {
            let side = conflict.sides.first { $0.stage == stage }
            let text = NSTextView(usingTextLayoutManager: true)
            text.frame = NSRect(x: 0, y: 0, width: 180, height: 65)
            text.isEditable = false; text.isRichText = false; text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            text.isVerticallyResizable = true; text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = true
            text.string = side.map { $0.text ?? "Binary or unsupported text · \($0.bytes) bytes · mode \($0.mode)" } ?? "Absent in this stage (addition/deletion)"
            text.setAccessibilityLabel(title + ": " + conflict.path)
            let scroll = NSScrollView(); scroll.documentView = text; scroll.hasVerticalScroller = true
            scroll.heightAnchor.constraint(equalToConstant: 150).isActive = true
            let use = NSButton(title: "Use " + (stage == 1 ? "Base" : stage == 2 ? "Ours" : "Theirs"), target: self, action: #selector(useSide(_:)))
            use.tag = stage; use.isEnabled = side != nil; buttons.append(use)
            let label = NSTextField(labelWithString: title); label.font = .systemFont(ofSize: 11); label.lineBreakMode = .byTruncatingTail; label.maximumNumberOfLines = 1; label.toolTip = title + (side.map { "\n" + $0.oid + " · mode " + $0.mode } ?? "\nAbsent stage")
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let pane = gitStack([label, scroll, use]); pane.widthAnchor.constraint(greaterThanOrEqualToConstant: 70).isActive = true
            panes.addArrangedSubview(pane)
        }
        panes.heightAnchor.constraint(equalToConstant: 220).isActive = true
        mark.target = self; mark.action = #selector(markWorking(_:))
        remove.target = self; remove.action = #selector(deleteResult(_:))
        status.font = .systemFont(ofSize: 11); status.maximumNumberOfLines = 2
        let open = NSButton(title: "Open result", target: self, action: #selector(openWorking(_:)))
        let result = resultLabel
        result.font = .systemFont(ofSize: 11, weight: .semibold)
        let stack = gitStack([gitStack([heading, NSView(), reload, close], vertical: false), panes, status, gitStack([mark, remove, open], vertical: false), result, resultHost])
        stack.spacing = 6
        gitPin(stack, to: view, inset: 8)
        resultHost.heightAnchor.constraint(greaterThanOrEqualToConstant: 80).isActive = true
        subscription = workspace.subscribe { [weak self] in self?.render() }
        render()
    }
    public func installEditor(_ editor: NSView?) {
        _ = view
        NSLayoutConstraint.deactivate(installedConstraints); installedConstraints = []
        installedEditor?.removeFromSuperview(); installedEditor = editor
        guard let editor else { render(); return }

        editor.translatesAutoresizingMaskIntoConstraints = false; resultHost.addSubview(editor)
        installedConstraints = [editor.topAnchor.constraint(equalTo: resultHost.topAnchor), editor.bottomAnchor.constraint(equalTo: resultHost.bottomAnchor), editor.leadingAnchor.constraint(equalTo: resultHost.leadingAnchor), editor.trailingAnchor.constraint(equalTo: resultHost.trailingAnchor)]
        NSLayoutConstraint.activate(installedConstraints); render()
    }
    @objc func useSide(_ sender: NSButton) {
        guard sender.isEnabled, let side = conflict.sides.first(where: { $0.stage == sender.tag }) else { return }

        if installedEditor != nil, side.text != nil, canEditResult?() == true { takeTextSide?(side) }
        else { restoreStage?(sender.tag) }
    }
    @objc func markWorking(_ sender: Any?) { if mark.isEnabled { resolveWorking?() } }
    @objc private func deleteResult(_ sender: Any?) { if remove.isEnabled { resolveDeleted?() } }
    @objc private func reopenContext(_ sender: Any?) { if workspace.canMutate { reopen?() } }
    @objc private func openWorking(_ sender: Any?) { openResult?() }
    @objc private func closeContext(_ sender: Any?) { closePreview?() }
    private func render() {
        resultLabel.stringValue = installedEditor != nil ? "Result · native editor (not staged until marked resolved)" : conflict.workingText != nil ? "Result · Open result in its owner window or edit externally" : "Result · absent/binary; restore a stage or edit externally, then Reload stages"
        let unresolved = workspace.snapshot?.repository == conflict.repository && workspace.snapshot?.changes.contains { $0.path == conflict.path && $0.decoration.isConflict } == true
        let enabled = workspace.canMutate && unresolved && conflict.supportsResolution
        mark.isEnabled = enabled && conflict.workingExists
        remove.isEnabled = enabled
        for button in buttons {
            let side = conflict.sides.first { $0.stage == button.tag }
            button.isEnabled = enabled && side != nil && (installedEditor == nil || side?.text == nil || canEditResult?() == true)
            button.toolTip = installedEditor != nil && side?.text != nil ? "Replace the native editor result as one undoable edit; does not stage" : "Restore stage blob on disk after explicit confirmation; does not mark resolved"
        }
        status.stringValue = !conflict.supportsResolution ? "Symlink/submodule conflicts need an external resolver." : unresolved ? "Review all changes before marking. Save stages only this path; remaining conflict markers are refused. Missing sides are not empty files. Reopen after external index/operation changes." : "This path is no longer unmerged. The preview is retained; close it to keep editing the document."
        if workspace.operationState.isBusy { status.stringValue = workspace.operationState.explanation }
        else if case .failed(let error) = workspace.operationState { status.stringValue = error }
    }
    public func disconnect() { if let subscription { workspace.unsubscribe(subscription) }; subscription = nil; installEditor(nil) }
}

@MainActor final class GitContextBackground: NSView {
    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance { NSColor.windowBackgroundColor.setFill(); dirtyRect.fill() }
    }
}

@MainActor private final class GitStageSplitView: NSSplitView, NSSplitViewDelegate {
    private var initializedWidths = false

    override init(frame frameRect: NSRect) { super.init(frame: frameRect); delegate = self }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
        guard !subviews.isEmpty else { return }

        let available = max(0, bounds.width - CGFloat(subviews.count - 1) * dividerThickness)
        guard available > 0 else { return }

        let previous = subviews.map { $0.frame.width }, total = previous.reduce(0, +)
        let weights = initializedWidths && total > 0 ? previous.map { $0 / total } : Array(repeating: 1 / CGFloat(subviews.count), count: subviews.count)
        initializedWidths = true
        var offset: CGFloat = 0
        for (index, child) in subviews.enumerated() {
            child.frame = NSRect(x: offset, y: 0, width: available * weights[index], height: bounds.height)
            offset += child.frame.width + dividerThickness
        }
    }
}
