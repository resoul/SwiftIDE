import AppKit

/// A strip above the editor that says one thing and offers a few ways to answer it. Hidden, it
/// takes no space.
@MainActor
public final class NoticeBanner: NSView {
    public struct Button {
        public let title: String
        public let action: @MainActor () -> Void

        public init(title: String, action: @escaping @MainActor () -> Void) {
            self.title = title
            self.action = action
        }
    }

    public private(set) var message = ""
    private let label = NSTextField(wrappingLabelWithString: "")
    private let buttons = NSStackView()
    private var actions: [@MainActor () -> Void] = []

    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .labelColor
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        buttons.orientation = .horizontal
        buttons.spacing = 8
        let row = NSStackView(views: [label, buttons])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        isHidden = true
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func updateLayer() {
        // Yellow mixed into the window's own colour, opaque, so that it reads in light and dark.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let mixed = NSColor.windowBackgroundColor.blended(withFraction: 0.28, of: .systemYellow)
            layer?.backgroundColor = (mixed ?? NSColor.systemYellow).cgColor
        }
    }

    public override var wantsUpdateLayer: Bool { true }

    public func show(message: String, buttons items: [Button]) {
        self.message = message
        label.stringValue = message
        buttons.arrangedSubviews.forEach { $0.removeFromSuperview() }
        actions = items.map(\.action)
        for (index, item) in items.enumerated() {
            let button = NSButton(title: item.title, target: self, action: #selector(pressed(_:)))
            button.controlSize = .small
            button.bezelStyle = .rounded
            button.tag = index
            buttons.addArrangedSubview(button)
        }
        isHidden = false
    }

    public func hide() {
        isHidden = true
    }

    @objc private func pressed(_ sender: NSButton) {
        guard actions.indices.contains(sender.tag) else { return }

        actions[sender.tag]()
    }
}

/// The editor with a notice strip above it.
@MainActor
public final class EditorContainerView: NSView {
    public let host: EditorHostView
    public let banner = NoticeBanner()

    public init(host: EditorHostView) {
        self.host = host
        super.init(frame: .zero)
        let stack = NSStackView(views: [banner, host])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.distribution = .fill
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            banner.widthAnchor.constraint(equalTo: stack.widthAnchor),
            host.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        host.setContentHuggingPriority(.defaultLow, for: .vertical)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
