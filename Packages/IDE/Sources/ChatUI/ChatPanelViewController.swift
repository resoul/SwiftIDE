import AppKit
import IDEApplication
import IDEDomain
import IconUI

@MainActor
public final class ChatPanelViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate,
    NSTextViewDelegate {
    public let session: AgentSession
    public var focusTarget: NSView { input }
    public var captureSelection: (() throws -> AgentContext)? {
        didSet { if isViewLoaded { updateActions() } }
    }
    public var copyText: (String) -> Void = {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString($0, forType: .string)
    }
    let table = NSTableView()
    let scroll = NSScrollView()
    let input = ChatComposerTextView()
    let send = NSButton(title: "Send", target: nil, action: nil)
    let stop = NSButton(title: "Stop", target: nil, action: nil)
    let latest = NSButton(title: "↓ Latest response", target: nil, action: nil)
    private let attach = NSButton(title: "Add selection", target: nil, action: nil)
    private let clear = NSButton()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let empty = NSTextField(wrappingLabelWithString: "")
    private let attachments = NSStackView()
    private let inputScroll = NSScrollView()
    private let inputUndo = UndoManager()
    private var inputHeight: NSLayoutConstraint?
    private var subscription: UUID?
    private var scheduled: Task<Void, Never>?
    private var disconnected = false
    private var syncingInput = false
    private var rendering = false
    private var messages: [AgentMessage] = []
    private var collapsed: [UUID: Set<UUID>] = [:]
    private var heights: [UUID: CGFloat] = [:]
    private var heightInputs: [UUID: (message: AgentMessage, width: CGFloat, collapsed: Set<UUID>)] = [:]
    private var width: CGFloat = 0
    private var contextIDs: [UUID] = []
    private var pendingAnchor: (UUID, CGFloat)?
    private var layingOut = false
    private(set) var followsLatest = true
    private(set) var renderCount = 0

    public init(session: AgentSession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func loadView() {
        view = ChatSurface(frame: NSRect(x: 0, y: 0, width: 380, height: 650))
        (view as? ChatSurface)?.fillColor = .windowBackgroundColor
        let title = NSTextField(labelWithString: "Agent chat")
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        let provider = NSTextField(labelWithString: session.info.name + (session.info.isDemo ? " · Demo" : ""))
        provider.font = .systemFont(ofSize: 10)
        provider.textColor = .secondaryLabelColor
        let identity = stack([title, provider], vertical: true)
        identity.spacing = 3
        clear.title = "Clear"
        clear.font = .systemFont(ofSize: 11)
        clear.setAccessibilityLabel("Clear chat")
        clear.isBordered = false
        clear.toolTip = "Clear this chat and its draft"
        clear.target = self
        clear.action = #selector(clearChat(_:))
        let header = stack([identity, NSView(), clear], vertical: false)
        header.heightAnchor.constraint(equalToConstant: 42).isActive = true
        table.addTableColumn(NSTableColumn(identifier: .init("Message")))
        table.headerView = nil
        table.intercellSpacing = NSSize(width: 0, height: 6)
        table.selectionHighlightStyle = .none
        table.autoresizingMask = [.width]
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel("Agent conversation")
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.verticalScrollElasticity = .none
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrolled(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scroll.contentView
        )
        empty.stringValue = "Chat with your workspace\n\n"
            + (session.info.isDemo ? "Local demo · no API calls or file changes.\n\n" : "")
            + "Write a message or attach an editor selection."
        empty.alignment = .center
        empty.font = .systemFont(ofSize: 13)
        empty.textColor = .secondaryLabelColor
        empty.maximumNumberOfLines = 7
        let history = ChatSurface()
        chatPin(scroll, to: history)
        empty.translatesAutoresizingMaskIntoConstraints = false
        history.addSubview(empty)
        NSLayoutConstraint.activate([
            empty.centerXAnchor.constraint(equalTo: history.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: history.centerYAnchor),
            empty.widthAnchor.constraint(lessThanOrEqualTo: history.widthAnchor, constant: -32)
        ])
        latest.target = self
        latest.action = #selector(showLatest(_:))
        latest.font = .systemFont(ofSize: 11)
        latest.isHidden = true
        attachments.orientation = .vertical
        attachments.alignment = .leading
        attachments.spacing = 4
        attachments.isHidden = true
        input.delegate = self
        for name in [Notification.Name.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange] {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(composerUndoChanged(_:)),
                name: name,
                object: inputUndo
            )
        }
        input.submit = { [weak self] in self?.submitMessage(nil) }
        input.compositionChanged = { [weak self] in self?.updateActions() }
        inputScroll.documentView = input
        inputScroll.hasVerticalScroller = true
        inputScroll.borderType = .lineBorder
        inputScroll.verticalScrollElasticity = .none
        inputScroll.wantsLayer = true
        inputScroll.layer?.cornerRadius = 10
        inputHeight = inputScroll.heightAnchor.constraint(equalToConstant: 58)
        inputHeight?.isActive = true
        input.autoresizingMask = [.width]
        send.target = self
        send.action = #selector(submitMessage(_:))
        stop.target = self
        stop.action = #selector(stopResponse(_:))
        attach.target = self
        attach.action = #selector(addSelection(_:))
        attach.font = .systemFont(ofSize: 11)
        status.font = .systemFont(ofSize: 10)
        status.textColor = .secondaryLabelColor
        status.maximumNumberOfLines = 3
        let composer = stack(
            [attachments, inputScroll, stack([attach, NSView(), stop, send], vertical: false), status],
            vertical: true
        )
        let content = stack([header, history, latest, composer], vertical: true)
        content.spacing = 10
        chatPin(content, to: view, inset: 10)
        subscription = session.subscribe { [weak self] in self?.scheduleRender() }
        renderNow()
    }

    private func stack(_ views: [NSView], vertical: Bool) -> NSStackView {
        let result = NSStackView(views: views)
        result.orientation = vertical ? .vertical : .horizontal
        result.alignment = vertical ? .leading : .centerY
        result.spacing = 6
        if vertical { for view in views { view.widthAnchor.constraint(equalTo: result.widthAnchor).isActive = true } }

        return result
    }

    private func scheduleRender() {
        guard !disconnected, scheduled == nil else { return }

        scheduled = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(33)) } catch { return }
            guard let self, !disconnected else { return }

            scheduled = nil
            renderNow()
        }
    }

    func renderNow() {
        guard !disconnected, isViewLoaded else { return }

        rendering = true
        renderCount += 1
        let anchor = pendingAnchor ?? visibleAnchor()
        pendingAnchor = nil
        let old = messages
        let values = session.messages
        let ids = Set(values.map(\.id))
        table.beginUpdates()
        for index in messages.indices.reversed() where !ids.contains(messages[index].id) {
            messages.remove(at: index)
            table.removeRows(at: IndexSet(integer: index), withAnimation: [])
        }
        for (index, message) in values.enumerated() {
            if !messages.contains(where: { $0.id == message.id }) {
                messages.insert(message, at: index)
                table.insertRows(at: IndexSet(integer: index), withAnimation: [])
            }
        }
        messages = values
        table.endUpdates()
        collapsed = collapsed.filter { ids.contains($0.key) }
        let changed = IndexSet(messages.indices.filter { index in
            old.first(where: { $0.id == messages[index].id }) != messages[index] || width != table.bounds.width
        })
        for index in changed {
            heights[messages[index].id] = nil
            (table.rowView(atRow: index, makeIfNecessary: false) as? ChatMessageRow)?.present(
                messages[index],
                collapsed: collapsed[messages[index].id] ?? []
            )
        }
        if !changed.isEmpty { table.noteHeightOfRows(withIndexesChanged: changed) }
        width = table.bounds.width
        heights = heights.filter { ids.contains($0.key) }
        heightInputs = heightInputs.filter { ids.contains($0.key) }
        empty.isHidden = !messages.isEmpty
        syncDraft()
        presentContexts()
        updateActions()
        view.layoutSubtreeIfNeeded()
        restoreScroll(anchor)
        rendering = false
        latest.isHidden = followsLatest || messages.isEmpty
    }

    private func syncDraft() {
        guard input.string != session.draft, !input.hasMarkedText() else { return }

        syncingInput = true
        input.breakUndoCoalescing()
        // The composer owns this manager: sending must be a separate undoable edit,
        // including when input and Send arrive in the same AppKit event.
        while inputUndo.groupingLevel > 0 { inputUndo.endUndoGrouping() }
        inputUndo.beginUndoGrouping()
        input.insertText(
            session.draft,
            replacementRange: NSRange(location: 0, length: (input.string as NSString).length)
        )
        input.breakUndoCoalescing()
        syncingInput = false
        resizeInput()
    }

    private func presentContexts() {
        guard contextIDs != session.contexts.map(\.id) else { return }

        contextIDs = session.contexts.map(\.id)
        for view in attachments.arrangedSubviews {
            attachments.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for context in session.contexts {
            let label = NSTextField(labelWithString: context.name + " · v\(context.version)")
            label.font = .systemFont(ofSize: 10)
            label.lineBreakMode = .byTruncatingMiddle
            label.toolTip = context.path
            let remove = ChatContextButton(contextID: context.id)
            remove.target = self
            remove.action = #selector(removeSelection(_:))
            attachments.addArrangedSubview(stack([label, remove], vertical: false))
        }
        attachments.isHidden = session.contexts.isEmpty
    }

    public override func viewWillLayout() {
        super.viewWillLayout()
        layingOut = true
        if !rendering, !followsLatest, pendingAnchor == nil { pendingAnchor = visibleAnchor() }
    }

    public override func viewDidLayout() {
        super.viewDidLayout()
        resizeInput()
        if abs(table.frame.width - scroll.contentSize.width) > 0.5 {
            if !rendering { pendingAnchor = visibleAnchor() }
            table.frame.size.width = max(1, scroll.contentSize.width)
        }

        if !rendering, abs(width - table.bounds.width) > 0.5 { scheduleRender() }
        layingOut = false
    }

    private func resizeInput() {
        let height = min(
            150,
            max(58, ChatTextView.height(input.string, width: inputScroll.contentSize.width - 16) + 16)
        )
        if inputHeight?.constant != height { inputHeight?.constant = height }
        input.frame.size = NSSize(width: max(1, inputScroll.contentSize.width), height: max(height, input.frame.height))
        input.needsDisplay = true
    }

    private func updateActions() {
        send.isEnabled = session.canSend && !input.hasMarkedText()
        stop.isHidden = session.state != .running && session.state != .cancelling
        stop.isEnabled = session.state == .running
        clear.isEnabled = session.canClear && !input.hasMarkedText()
        attach.isEnabled = captureSelection != nil && session.state != .stopped
        input.isEditable = session.state != .stopped
        if let error = session.inputError { status.stringValue = error }
        else {
            switch session.state {
            case .running: status.stringValue = "Responding… · Enter sends; Shift+Enter adds a line"
            case .cancelling: status.stringValue = "Stopping…"
            case .failed(let error): status.stringValue = error
            case .stopped: status.stringValue = "Chat closed"
            case .ready:
                status.stringValue = session.info.isDemo
                    ? "Demo · Enter sends; Shift+Enter adds a line"
                    : "Enter sends; Shift+Enter adds a line"
            }
        }

        status.toolTip = status.stringValue
    }

    public func textDidChange(_ notification: Notification) {
        guard !syncingInput else { return }

        session.setDraft(input.string)
        resizeInput()
        updateActions()
    }

    public func undoManager(for view: NSTextView) -> UndoManager? { inputUndo }

    @objc private func composerUndoChanged(_ notification: Notification) {
        session.setDraft(input.string)
        resizeInput()
        updateActions()
    }

    public func textView(
        _ textView: NSTextView,
        shouldChangeTextIn affectedCharRange: NSRange,
        replacementString: String?
    ) -> Bool {
        guard !syncingInput, !input.hasMarkedText(), let replacementString else { return true }

        let old = input.string as NSString
        guard affectedCharRange.location <= old.length,
              affectedCharRange.length <= old.length - affectedCharRange.location else {
            return false
        }

        let bytes = input.string.utf8.count - old.substring(with: affectedCharRange).utf8.count + replacementString.utf8
            .count
        if bytes > 64_000 {
            session.reportInputError("Message limit: 64 KB.")

            return false
        }

        return true
    }

    @objc func submitMessage(_ sender: Any?) {
        guard !disconnected, !input.hasMarkedText() else { return }

        session.setDraft(input.string)
        if session.send() {
            followsLatest = true
            renderNow()
        }
    }

    @objc private func stopResponse(_ sender: Any?) { session.cancel() }

    @objc private func clearChat(_ sender: Any?) {
        guard !input.hasMarkedText(), session.canClear else { return }

        session.clear()
        followsLatest = true
        collapsed = [:]
        renderNow()
        input.undoManager?.removeAllActions()
    }

    @objc func addSelection(_ sender: Any?) {
        do {
            guard let captureSelection else { return }

            _ = session.attach(try captureSelection())
        } catch { session.reportInputError(error.localizedDescription) }
    }

    @objc private func removeSelection(_ sender: ChatContextButton) { session.removeContext(sender.contextID) }

    public func numberOfRows(in tableView: NSTableView) -> Int { messages.count }

    public func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        nil
    }

    public func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    public func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard messages.indices.contains(row) else { return 1 }

        let message = messages[row]
        let folded = collapsed[message.id] ?? []
        if let previous = heightInputs[message.id], previous.message == message,
           previous.width == table.bounds.width, previous.collapsed == folded,
           let height = heights[message.id] { return height }

        let value = ChatMessageRow.height(message, width: table.bounds.width, collapsed: folded)
        heights[message.id] = value
        heightInputs[message.id] = (message, table.bounds.width, folded)

        return value
    }

    public func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        guard messages.indices.contains(row) else { return nil }

        let identifier = NSUserInterfaceItemIdentifier("ChatMessage")
        let view = (table.makeView(withIdentifier: identifier, owner: self) as? ChatMessageRow) ?? ChatMessageRow()
        view.identifier = identifier
        view.copyText = { [weak self] in self?.copyText($0) }
        let messageID = messages[row].id
        view.toggleTool = { [weak self, weak view] id in
            guard let self, let index = messages.firstIndex(where: { $0.id == messageID }) else { return }

            pendingAnchor = visibleAnchor()
            if collapsed[messageID, default: []].contains(id) { collapsed[messageID]?.remove(id) }
            else { collapsed[messageID, default: []].insert(id) }

            heightInputs[messageID] = nil
            rendering = true
            view?.present(messages[index], collapsed: collapsed[messageID] ?? [])
            table.noteHeightOfRows(withIndexesChanged: IndexSet(integer: index))
            rendering = false
            renderNow()
        }
        view.present(messages[row], collapsed: collapsed[messageID] ?? [])

        return view
    }

    private func visibleAnchor() -> (UUID, CGFloat)? {
        let rows = table.rows(in: scroll.contentView.bounds)
        guard rows.location != NSNotFound, messages.indices.contains(rows.location) else { return nil }

        return (messages[rows.location].id, scroll.contentView.bounds.minY - table.rect(ofRow: rows.location).minY)
    }

    private func restoreScroll(_ anchor: (UUID, CGFloat)?) {
        let y: CGFloat
        if followsLatest { y = max(0, table.bounds.height - scroll.contentView.bounds.height) }
        else if let anchor, let row = messages.firstIndex(where: { $0.id == anchor.0 }) {
            y = table.rect(ofRow: row).minY + anchor.1
        } else { return }

        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    @objc private func scrolled(_ notification: Notification) {
        guard !rendering, !layingOut else { return }

        followsLatest = table.bounds.height - scroll.contentView.bounds.maxY <= 24
        latest.isHidden = followsLatest || messages.isEmpty
    }

    @objc func showLatest(_ sender: Any?) {
        followsLatest = true
        rendering = true
        restoreScroll(nil)
        rendering = false
        latest.isHidden = true
    }

    public func disconnect() {
        disconnected = true
        scheduled?.cancel()
        if let subscription { session.unsubscribe(subscription) }
        subscription = nil
        NotificationCenter.default.removeObserver(self)
    }
}

@MainActor
private final class ChatContextButton: NSButton {
    let contextID: UUID

    init(contextID: UUID) {
        self.contextID = contextID
        super.init(frame: .zero)
        image = TablerIcon.x.image(accessibilityDescription: "Remove selection")
        isBordered = false
        setAccessibilityLabel("Remove attached selection")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
