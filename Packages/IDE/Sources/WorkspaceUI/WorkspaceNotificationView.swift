import AppKit

/// A pass-through overlay; only the visible card stack participates in hit testing.
@MainActor
final class WorkspaceNotificationOverlay: NSView {
    let notifications: WorkspaceNotifications
    let scroll = NSScrollView.nonElastic()
    private let stack = NSStackView()
    private(set) var cards: [WorkspaceNotificationCard] = []
    private var subscription: UUID?
    private var width: NSLayoutConstraint!
    private var height: NSLayoutConstraint!
    var restoreFocus: (() -> Void)?
    private var revealNewest = false

    init(notifications: WorkspaceNotifications) {
        self.notifications = notifications
        super.init(frame: .zero)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        scroll.setAccessibilityLabel("Workspace notifications")
        let document = NotificationDocumentView()
        scroll.documentView = document
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        document.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor)
        ])
        addSubview(scroll)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        width = scroll.widthAnchor.constraint(equalToConstant: 370)
        height = scroll.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            width,
            height
        ])
        subscription = notifications.subscribe { [weak self] in self?.render() }
        render()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)

        return hit === self ? nil : hit
    }

    override func layout() {
        super.layout()
        width.constant = max(0, min(370, bounds.width - 24))
        let size = stack.fittingSize
        height.constant = max(0, min(size.height, min(360, bounds.height * 0.5)))
        if revealNewest {
            scroll.layoutSubtreeIfNeeded()
            if let document = scroll.documentView {
                document.layoutSubtreeIfNeeded()
                let bottom = max(0, document.bounds.height - height.constant)
                let newestTop = cards.last.map { document.convert($0.bounds, from: $0).minY } ?? 0
                scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, min(bottom, newestTop))))
                scroll.reflectScrolledClipView(scroll.contentView)
            }

            revealNewest = false
        }
    }

    func disconnect() {
        if let subscription { notifications.unsubscribe(subscription) }
        subscription = nil
        restoreFocus = nil
        for card in cards { card.disconnect() }
    }

    private func render() {
        let focused = window?.firstResponder as? NSView
        let hadFocus = focused?.isDescendant(of: self) == true
        let ids = Set(notifications.items.map(\.id))
        for card in cards where !ids.contains(card.id) {
            card.disconnect()
            stack.removeArrangedSubview(card)
            card.removeFromSuperview()
        }
        cards.removeAll { !ids.contains($0.id) }
        for item in notifications.items {
            if let card = cards.first(where: { $0.id == item.id }) {
                card.present(item)
            } else {
                let card = WorkspaceNotificationCard(item: item) { [weak notifications] in
                    notifications?.dismiss(item.id)
                }
                cards.append(card)
                revealNewest = true
                stack.addArrangedSubview(card)
                card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
        }
        scroll.isHidden = cards.isEmpty
        needsLayout = true
        if hadFocus, focused?.isDescendant(of: self) != true { restoreFocus?() }
    }
}

@MainActor
private final class NotificationDocumentView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
final class WorkspaceNotificationCard: NSView {
    let id: String
    let title = NSTextField(wrappingLabelWithString: "")
    let message = NSTextField(wrappingLabelWithString: "")
    let close = NSButton()
    private let icon = NSImageView()
    private let content = NSStackView()
    private(set) var actionButtons: [NSButton] = []
    private var actions: [WorkspaceNotificationAction] = []
    private var dismiss: (() -> Void)?
    private var kind: WorkspaceNotificationKind = .information

    init(item: WorkspaceNotification, dismiss: @escaping () -> Void) {
        id = item.id
        self.dismiss = dismiss
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        setAccessibilityElement(false)
        setAccessibilityRole(.group)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        message.font = .systemFont(ofSize: 13)
        for field in [title, message] {
            field.maximumNumberOfLines = 0
            field.setContentCompressionResistancePriority(.required, for: .vertical)
        }
        close.image = WorkspaceIcon.image("xmark", description: "Dismiss notification")
        close.imageScaling = .scaleProportionallyDown
        close.isBordered = false
        close.target = self
        close.action = #selector(closeCard(_:))
        close.toolTip = "Dismiss notification"
        close.setAccessibilityLabel("Dismiss notification")
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 5
        content.addArrangedSubview(title)
        content.addArrangedSubview(message)
        for child in [icon, content, close] {
            addSubview(child)
            child.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            icon.topAnchor.constraint(equalTo: topAnchor, constant: 13),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            close.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            close.widthAnchor.constraint(equalToConstant: 20),
            close.heightAnchor.constraint(equalToConstant: 20),
            content.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            content.trailingAnchor.constraint(equalTo: close.leadingAnchor, constant: -4),
            content.topAnchor.constraint(equalTo: topAnchor, constant: 11),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            title.widthAnchor.constraint(equalTo: content.widthAnchor),
            message.widthAnchor.constraint(equalTo: content.widthAnchor)
        ])
        present(item)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func present(_ item: WorkspaceNotification) {
        kind = item.kind
        title.stringValue = item.title
        message.stringValue = item.message
        message.isHidden = item.message.isEmpty
        setAccessibilityLabel(item.kind.rawValue.capitalized + ": " + item.title)
        close.setAccessibilityLabel("Dismiss " + item.title)
        // Keep existing controls when replacing a card so a focused action is not detached.
        while actionButtons.count > item.actions.count {
            let button = actionButtons.removeLast()
            content.removeArrangedSubview(button)
            button.removeFromSuperview()
        }
        while actionButtons.count < item.actions.count {
            let button = NSButton(title: "", target: self, action: #selector(runAction(_:)))
            button.isBordered = false
            button.alignment = .left
            button.font = .systemFont(ofSize: 13)
            button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            content.addArrangedSubview(button)
            button.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor).isActive = true
            actionButtons.append(button)
        }
        actions = item.actions
        for (index, action) in actions.enumerated() {
            let button = actionButtons[index]
            button.title = action.title
            button.toolTip = action.title
            button.tag = index
            button.contentTintColor = .linkColor
        }
        let colour: NSColor = switch kind {
        case .information: .systemBlue
        case .success: .systemGreen
        case .warning: .systemOrange
        case .error: .systemRed
        }
        let symbol = switch kind {
        case .information: "info.circle"
        case .success: "checkmark.circle"
        case .warning: "exclamationmark.triangle"
        case .error: "exclamationmark.circle"
        }
        icon.image = WorkspaceIcon.image(symbol, description: kind.rawValue.capitalized)
        icon.contentTintColor = colour
        title.textColor = .labelColor
        message.textColor = .labelColor
        close.contentTintColor = .secondaryLabelColor
        needsDisplay = true
    }

    func disconnect() { actions = []; dismiss = nil }
    override var wantsUpdateLayer: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            layer?.backgroundColor = NSColor(white: dark ? 0.205 : 0.94, alpha: 1).cgColor
        }
    }

    @objc private func closeCard(_ sender: NSButton) { dismiss?() }

    @objc private func runAction(_ sender: NSButton) {
        guard actions.indices.contains(sender.tag) else { return }

        actions[sender.tag].perform()
    }
}
