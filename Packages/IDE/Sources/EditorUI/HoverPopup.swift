import AppKit
import IDEApplication
import IDEDomain

private final class HoverPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The description of a symbol, or the problem at a place, in a small window under the text. It never
/// takes the keyboard or the pointer: it only shows.
@MainActor
public final class HoverPopup: NSObject, HoverPresenting {
    public static let maximumWidth: CGFloat = 480
    static let maximumLines = 16
    static let maximumCharacters = 1_600

    private weak var textView: NSTextView?
    private let panel: HoverPanel
    private let label = NSTextField(wrappingLabelWithString: "")
    private var observers: [NSObjectProtocol] = []
    public private(set) var isVisible = false
    public private(set) var text = ""

    /// Something happened that makes the window out of place (the window lost the keyboard, the
    /// text scrolled): the owner dismisses it.
    public var onClose: (() -> Void)?

    public init(textView: NSTextView) {
        self.textView = textView
        panel = HoverPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 40),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = true
        panel.ignoresMouseEvents = true

        let effect = NSVisualEffectView()
        effect.material = .toolTip
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 5
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 0.5
        effect.layer?.borderColor = NSColor.separatorColor.cgColor
        panel.contentView = effect

        label.font = .systemFont(ofSize: 12)
        label.textColor = .labelColor
        label.isSelectable = false
        label.maximumNumberOfLines = Self.maximumLines
        label.lineBreakMode = .byTruncatingTail
        label.preferredMaxLayoutWidth = Self.maximumWidth - 20
        label.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: effect.topAnchor, constant: 6),
            label.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -6),
        ])
    }

    isolated deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        panel.orderOut(nil)
    }

    // MARK: HoverPresenting

    public func show(_ text: String, anchor: UTF16TextRange) {
        guard let textView, let window = textView.window else { return }

        let shown = Self.trimmed(text)
        self.text = shown
        label.stringValue = shown
        let size = Self.size(of: shown, font: label.font ?? .systemFont(ofSize: 12))
        let frame = CompletionPopup.frame(
            size: size,
            below: textView.firstRect(forCharacterRange: NSRange(location: anchor.location, length: 0), actualRange: nil),
            visibleScreen: (window.screen ?? NSScreen.main)?.visibleFrame
        )
        panel.setFrame(frame, display: true)
        if !isVisible {
            window.addChildWindow(panel, ordered: .above)
            panel.orderFront(nil)
            isVisible = true
            watchForReasonsToClose(in: window, textView: textView)
        }
    }

    public func dismiss() {
        guard isVisible else { return }

        isVisible = false
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }

    // MARK: Text and size

    /// At most the lines and characters a tooltip should have; a cut is marked.
    static func trimmed(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        var cut = false
        if lines.count > maximumLines {
            lines = Array(lines.prefix(maximumLines))
            cut = true
        }

        var result = lines.joined(separator: "\n")
        if result.count > maximumCharacters {
            result = String(result.prefix(maximumCharacters))
            cut = true
        }

        return cut ? result + "…" : result
    }

    static func size(of text: String, font: NSFont) -> NSSize {
        let bounds = (text as NSString).boundingRect(
            with: NSSize(width: maximumWidth - 20, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )

        return NSSize(width: min(maximumWidth, max(80, ceil(bounds.width) + 24)), height: ceil(bounds.height) + 14)
    }

    private func watchForReasonsToClose(in window: NSWindow, textView: NSTextView) {
        let center = NotificationCenter.default
        var names: [(Notification.Name, AnyObject?)] = [
            (NSWindow.didResignKeyNotification, window),
            (NSWindow.didResizeNotification, window),
            (NSApplication.didResignActiveNotification, nil),
        ]
        if let clip = textView.enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            names.append((NSView.boundsDidChangeNotification, clip))
        }

        for (name, object) in names {
            observers.append(center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onClose?() }
            })
        }
    }
}
