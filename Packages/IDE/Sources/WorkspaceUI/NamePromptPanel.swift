import AppKit

/// What a name prompt says: its title, what the empty field says and the icon beside the field.
public struct NamePrompt: Equatable, Sendable {
    public var title: String
    public var placeholder: String
    public var icon: String
    /// The text the field starts with; empty for a new name.
    public var initialText: String
    /// With `initialText`, select only the part before the extension, as Finder does for a rename.
    public var selectsBaseName: Bool

    public init(
        title: String,
        placeholder: String = "Name",
        icon: String = "doc.text",
        initialText: String = "",
        selectsBaseName: Bool = false
    ) {
        self.title = title
        self.placeholder = placeholder
        self.icon = icon
        self.initialText = initialText
        self.selectsBaseName = selectsBaseName
    }
}

/// A small floating box over a window that asks for one name. Return hands the text to `submit`,
/// which answers nil to accept it (the box closes) or a message to show under the field (the box
/// stays, so the name can be fixed). Escape, or leaving the box, cancels.
@MainActor
public final class NamePromptPanel: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    public let field = NSTextField()
    private let errorLabel = NSTextField(labelWithString: "")
    private let panel: NSPanel
    private weak var parent: NSWindow?
    private let submit: (String) -> String?
    private let onClose: () -> Void
    private var isClosing = false
    private let initialText: String
    private let selectsBaseName: Bool
    private static let width: CGFloat = 400

    public init(
        prompt: NamePrompt,
        over parent: NSWindow?,
        submit: @escaping (String) -> String?,
        onClose: @escaping () -> Void = {}
    ) {
        self.parent = parent
        initialText = prompt.initialText
        selectsBaseName = prompt.selectsBaseName
        self.submit = submit
        self.onClose = onClose
        panel = Panel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 86),
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
        super.init()
        build(prompt)
    }

    public var window: NSWindow { panel }

    public var errorMessage: String? { errorLabel.isHidden ? nil : errorLabel.stringValue }

    public func show() {
        place()
        parent?.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        if !initialText.isEmpty { selectInitialText() }
    }

    private func selectInitialText() {
        let name = field.stringValue as NSString
        let base = selectsBaseName ? (name.deletingPathExtension as NSString).length : name.length
        let length = base == 0 ? name.length : base
        field.currentEditor()?.selectedRange = NSRange(location: 0, length: length)
    }

    /// Hands the text to `submit` as Return would.
    public func commit() {
        guard !isClosing else { return }

        if let message = submit(field.stringValue) {
            showError(message)
        } else {
            close(refocus: true)
        }
    }

    public func cancel() { close(refocus: true) }

    private func close(refocus: Bool) {
        guard !isClosing else { return }

        isClosing = true
        parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        if refocus { parent?.makeKeyAndOrderFront(nil) }

        onClose()
    }

    private func showError(_ message: String) {
        errorLabel.stringValue = message
        errorLabel.isHidden = false
        resize(extra: 22)
    }

    private func resize(extra: CGFloat) {
        var frame = panel.frame
        let height = 86 + extra
        frame.origin.y += frame.height - height
        frame.size.height = height
        panel.setFrame(frame, display: true)
    }

    private func place() {
        guard let frame = parent?.frame ?? NSScreen.main?.visibleFrame else { return }

        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.maxY - size.height - 160))
    }

    private func build(_ prompt: NamePrompt) {
        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.masksToBounds = true
        background.layer?.borderWidth = 1
        background.layer?.borderColor = NSColor.separatorColor.cgColor

        let title = NSTextField(labelWithString: prompt.title)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.alignment = .center
        let icon = NSImageView(image: WorkspaceIcon.image(prompt.icon, description: nil) ?? NSImage())
        icon.contentTintColor = .secondaryLabelColor
        icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 16).isActive = true
        field.stringValue = prompt.initialText
        field.placeholderString = prompt.placeholder
        field.setAccessibilityLabel(prompt.placeholder)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 14)
        field.delegate = self
        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.textColor = .systemRed
        errorLabel.isHidden = true
        errorLabel.lineBreakMode = .byTruncatingTail
        let row = NSStackView(views: [icon, field])
        row.orientation = .horizontal
        row.spacing = 8
        let stack = NSStackView(views: [title, row, errorLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: background.topAnchor, constant: 14),
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -16),
            title.widthAnchor.constraint(equalTo: stack.widthAnchor),
            row.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        panel.contentView = background
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.delegate = self
        panel.setAccessibilityLabel(prompt.title)
    }

    // MARK: Keys and focus

    public func controlTextDidChange(_ notification: Notification) {
        guard !errorLabel.isHidden else { return }

        errorLabel.isHidden = true
        resize(extra: 0)
    }

    public func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)): commit()
        case #selector(NSResponder.cancelOperation(_:)): cancel()
        default: return false
        }

        return true
    }

    public func windowDidResignKey(_ notification: Notification) {
        guard !isClosing, panel.isVisible else { return }

        close(refocus: false)
    }
}
