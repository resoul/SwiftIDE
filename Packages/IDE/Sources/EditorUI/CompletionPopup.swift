import AppKit
import IDEApplication

/// A panel that is shown beside the editor and never takes the keyboard from it.
private final class CompletionPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The list of completions, under the character where the word begins. It shows rows and reports
/// clicks; which row is chosen, and what happens then, is the controller's.
@MainActor
public final class CompletionPopup: NSObject, CompletionPresenting, NSTableViewDataSource, NSTableViewDelegate {
    public static let rowHeight: CGFloat = 20
    public static let maximumVisibleRows = 10

    private weak var textView: NSTextView?
    private let panel: CompletionPanel
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let statusLabel = NSTextField(labelWithString: "")
    private var rows: [CompletionRow] = []
    private var observers: [NSObjectProtocol] = []
    public private(set) var isVisible = false

    /// A click on a row (single: choose it; double: accept it).
    public var onClick: ((_ row: Int, _ isDouble: Bool) -> Void)?

    public init(textView: NSTextView) {
        self.textView = textView
        panel = CompletionPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 100),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true
        )
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = true
        panel.becomesKeyOnlyIfNeeded = true

        let effect = NSVisualEffectView()
        effect.material = .menu
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 6
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 0.5
        effect.layer?.borderColor = NSColor.separatorColor.cgColor
        panel.contentView = effect

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("row"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.backgroundColor = .clear
        table.allowsEmptySelection = false
        table.allowsMultipleSelection = false
        table.selectionHighlightStyle = .regular
        table.focusRingType = .none
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        table.doubleAction = #selector(doubleClicked)

        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(scroll)
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.isHidden = true
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusLabel.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 10),
            statusLabel.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -10),
            statusLabel.centerYAnchor.constraint(equalTo: effect.centerYAnchor),
            scroll.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: effect.topAnchor, constant: 3),
            scroll.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -3),
        ])
    }

    isolated deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        panel.orderOut(nil)
    }

    // MARK: CompletionPresenting

    public func present(rows: [CompletionRow], selected: Int, anchorOffset: Int) {
        guard let textView, let window = textView.window else { return }
        self.rows = rows
        statusLabel.isHidden = true
        scroll.isHidden = false
        table.reloadData()
        select(selected)

        let visibleRows = min(rows.count, Self.maximumVisibleRows)
        place(size: NSSize(width: preferredWidth(), height: CGFloat(visibleRows) * Self.rowHeight + 6), anchorOffset: anchorOffset, textView: textView, window: window)
    }

    public func showStatus(_ status: CompletionStatus, anchorOffset: Int) {
        guard let textView, let window = textView.window else { return }
        rows = []
        table.reloadData()
        scroll.isHidden = true
        statusLabel.stringValue = Self.text(for: status)
        statusLabel.isHidden = false
        let width = ceil(statusLabel.intrinsicContentSize.width) + 24
        place(size: NSSize(width: min(max(width, 160), 420), height: Self.rowHeight + 10), anchorOffset: anchorOffset, textView: textView, window: window)
    }

    static func text(for status: CompletionStatus) -> String {
        switch status {
        case .waiting: "Waiting for SourceKit…"
        case .starting: "SourceKit is starting…"
        case .restarting: "SourceKit is restarting…"
        case .notReady: "SourceKit is not ready yet"
        case .noSuggestions: "No suggestions"
        case .unavailable: "SourceKit is not available"
        case .notResponding: "SourceKit is not responding"
        }
    }

    private func place(size: NSSize, anchorOffset: Int, textView: NSTextView, window: NSWindow) {
        let frame = Self.frame(
            size: size,
            below: textView.firstRect(forCharacterRange: NSRange(location: anchorOffset, length: 0), actualRange: nil),
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

    public func select(_ index: Int) {
        guard rows.indices.contains(index) else { return }
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        table.scrollRowToVisible(index)
    }

    public func dismiss() {
        guard isVisible else { return }
        isVisible = false
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        rows = []
    }

    /// The popup's frame: its left edge under the character, below the line; above the line if
    /// there is no room below, and always inside the screen.
    static func frame(size: NSSize, below character: NSRect, visibleScreen: NSRect?) -> NSRect {
        var origin = NSPoint(x: character.minX - 8, y: character.minY - size.height - 2)
        if let screen = visibleScreen {
            if origin.y < screen.minY { origin.y = character.maxY + 2 }
            origin.x = min(max(origin.x, screen.minX), screen.maxX - size.width)
        }
        return NSRect(origin: origin, size: size)
    }

    private func preferredWidth() -> CGFloat {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let widest = rows.prefix(200).map { row -> CGFloat in
            let label = (row.label as NSString).size(withAttributes: [.font: font]).width
            let detail = ((row.detail ?? "") as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11)]).width
            return 26 + label + 16 + detail + 12
        }.max() ?? 280
        return min(max(widest, 280), 560)
    }

    private func watchForReasonsToClose(in window: NSWindow, textView: NSTextView) {
        let center = NotificationCenter.default
        var names: [(Notification.Name, AnyObject?)] = [
            (NSWindow.didResignKeyNotification, window), (NSWindow.didResizeNotification, window),
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

    /// Something happened that makes the list stale (the window lost the keyboard, the text scrolled).
    public var onClose: (() -> Void)?

    // MARK: Table

    @objc private func clicked() {
        guard table.clickedRow >= 0 else { return }
        onClick?(table.clickedRow, false)
    }

    @objc private func doubleClicked() {
        guard table.clickedRow >= 0 else { return }
        onClick?(table.clickedRow, true)
    }

    public func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? CompletionCell) ?? CompletionCell()
        cell.identifier = id
        cell.configure(rows[row])
        return cell
    }
}

private final class CompletionCell: NSView {
    private let glyph = NSTextField(labelWithString: "")
    private let label = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        glyph.font = .systemFont(ofSize: 10, weight: .bold)
        glyph.alignment = .center
        glyph.textColor = .white
        glyph.wantsLayer = true
        glyph.layer?.cornerRadius = 3
        label.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        label.lineBreakMode = .byTruncatingTail
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.alignment = .right
        detail.lineBreakMode = .byTruncatingHead
        for view in [glyph, label, detail] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
        NSLayoutConstraint.activate([
            glyph.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
            glyph.widthAnchor.constraint(equalToConstant: 14),
            glyph.heightAnchor.constraint(equalToConstant: 14),
            label.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: 6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            detail.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 12),
            detail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            detail.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(_ row: CompletionRow) {
        label.stringValue = row.label
        detail.stringValue = row.detail ?? ""
        let (letter, color) = Self.style(row.kind)
        glyph.stringValue = letter
        glyph.layer?.backgroundColor = color.cgColor
    }

    private static func style(_ kind: CompletionKind) -> (String, NSColor) {
        switch kind {
        case .method, .function: ("M", .systemPurple)
        case .initializer: ("I", .systemPurple)
        case .property: ("P", .systemTeal)
        case .variable: ("V", .systemTeal)
        case .type: ("T", .systemOrange)
        case .keyword: ("K", .systemPink)
        case .constant: ("C", .systemBlue)
        case .module: ("◻︎", .systemGray)
        case .other: ("·", .systemGray)
        }
    }
}
