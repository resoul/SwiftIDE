import AppKit
import IDEApplication

/// The command palette: a search field over a list of commands. It only presents and reports what
/// was chosen; what a command does, and whether it can run, is the application's.
@MainActor
public final class CommandPaletteViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate,
    NSSearchFieldDelegate {
    static let limit = 200

    /// The user chose a command that can run now.
    public var run: ((PaletteCommand) -> Void)?
    /// The user dismissed the palette with Escape.
    public var cancel: (() -> Void)?
    /// What the search field says when empty.
    public var placeholder = "Type a command" { didSet { search.placeholderString = placeholder } }
    /// What to list for a typed query, when the list is not simply the commands handed to `present`
    /// (Quick Open asks its index). Called on every keystroke.
    public var listing: ((String) -> [PaletteCommand])?
    /// Shown instead of the list when nothing matches.
    public var emptyMessage = "No matching commands" { didSet { empty.stringValue = emptyMessage } }

    let search = NSSearchField()
    let table = NSTableView()
    private let empty = NSTextField(labelWithString: "No matching commands")
    private var all: [PaletteCommand] = []
    /// What the list shows now, best first.
    public private(set) var results: [PaletteCommand] = []

    public init() { super.init(nibName: nil, bundle: nil) }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func loadView() {
        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.masksToBounds = true
        view = background
        view.frame = NSRect(x: 0, y: 0, width: 560, height: 340)

        search.placeholderString = placeholder
        search.setAccessibilityLabel("Search commands")
        search.delegate = self
        search.focusRingType = .none
        search.controlSize = .large
        search.font = .systemFont(ofSize: 15)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Command"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 28
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.style = .plain
        table.backgroundColor = .clear
        table.allowsEmptySelection = false
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked(_:))
        table.setAccessibilityLabel("Commands")

        let scroll = NSScrollView.nonElastic()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        empty.textColor = .secondaryLabelColor
        empty.alignment = .center
        empty.isHidden = true
        for child in [search, scroll, empty] {
            child.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child)
        }
        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            search.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            search.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -6),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),
            empty.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor)
        ])
    }

    /// Shows `commands` with an empty query and puts the caret in the search field.
    public func present(_ commands: [PaletteCommand]) {
        _ = view
        all = commands
        search.stringValue = ""
        refresh()
        view.window?.makeFirstResponder(search)
    }

    /// Lists again for the query typed so far, keeping the selected command if it is still there.
    public func refreshResults() {
        _ = view
        let selected = selectedCommand?.id
        refresh()
        if let selected, let row = results.firstIndex(where: { $0.id == selected }) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
    }

    /// What was typed in the search field; setting it lists again, as typing would.
    public var query: String {
        get { search.stringValue }
        set {
            _ = view
            search.stringValue = newValue
            refresh()
        }
    }

    public func focusSearch() { view.window?.makeFirstResponder(search) }

    public var selectedCommand: PaletteCommand? {
        results.indices.contains(table.selectedRow) ? results[table.selectedRow] : nil
    }

    public func controlTextDidChange(_ notification: Notification) { refresh() }

    public func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): move(by: 1)
        case #selector(NSResponder.moveUp(_:)): move(by: -1)
        case #selector(NSResponder.insertNewline(_:)): runSelected()
        case #selector(NSResponder.cancelOperation(_:)): cancel?()
        default: return false
        }

        return true
    }

    func move(by step: Int) {
        guard !results.isEmpty else { return }

        let row = min(max(0, table.selectedRow + step), results.count - 1)
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    func runSelected() {
        guard let command = selectedCommand, command.isEnabled else { return NSSound.beep() }

        run?(command)
    }

    @objc private func rowClicked(_ sender: Any?) { runSelected() }

    private func refresh() {
        let found = listing?(search.stringValue) ?? CommandSearch.rank(search.stringValue, in: all)
        results = Array(found.prefix(Self.limit))
        table.reloadData()
        empty.isHidden = !results.isEmpty
        if !results.isEmpty {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            table.scrollRowToVisible(0)
        }
    }

    // MARK: Table

    public func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        CommandPaletteRow(command: results[row])
    }
}

private final class CommandPaletteRow: NSTableCellView {
    init(command: PaletteCommand) {
        super.init(frame: .zero)
        let title = NSTextField(labelWithString: command.title)
        title.font = .systemFont(ofSize: 13)
        title.textColor = command.isEnabled ? .labelColor : .disabledControlTextColor
        title.lineBreakMode = .byTruncatingTail
        let group = NSTextField(labelWithString: command.group)
        group.font = .systemFont(ofSize: 11)
        group.textColor = .secondaryLabelColor
        let shortcut = NSTextField(labelWithString: command.shortcut ?? "")
        shortcut.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        shortcut.textColor = .secondaryLabelColor
        shortcut.alignment = .right
        for label in [title, group, shortcut] {
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
        }
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            group.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 8),
            group.centerYAnchor.constraint(equalTo: centerYAnchor),
            shortcut.leadingAnchor.constraint(greaterThanOrEqualTo: group.trailingAnchor, constant: 12),
            shortcut.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            shortcut.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        shortcut.setContentHuggingPriority(.required, for: .horizontal)
        setAccessibilityLabel([command.title, command.group, command.shortcut].compactMap { $0 }
            .joined(separator: ", "))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
