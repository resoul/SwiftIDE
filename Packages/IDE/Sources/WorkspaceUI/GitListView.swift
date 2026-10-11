import AppKit

struct GitListRow: Equatable {
    let key: String
    let title: String
    var detail = ""
    var colour: NSColor = .labelColor
    var selectable = true
}

@MainActor
final class GitListView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    let table = GitListTable()
    private(set) var rows: [GitListRow] = []
    var onSelect: ((String) -> Void)?
    var onOpen: ((String) -> Void)?
    private var rendering = false
    var selectedKey: String? { rows.indices.contains(table.selectedRow) ? rows[table.selectedRow].key : nil }

    init(label: String) {
        super.init(frame: .zero)
        let column = NSTableColumn(identifier: .init("GitItem"))
        table.addTableColumn(column); table.headerView = nil; table.rowHeight = 42
        table.dataSource = self; table.delegate = self; table.target = self
        table.doubleAction = #selector(openSelected(_:))
        table.openSelection = { [weak self] in self?.openSelected(nil) }
        table.setAccessibilityLabel(label)
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.documentView = table
        gitPin(scroll, to: self)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func present(_ values: [GitListRow]) {
        guard values != rows else { return }

        let selected = selectedKey
        rendering = true
        rows = values; table.reloadData()
        if let selected, let index = rows.firstIndex(where: { $0.key == selected && $0.selectable }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else { table.deselectAll(nil) }

        rendering = false
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { rows.indices.contains(row) && rows[row].selectable }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !rendering, let key = selectedKey else { return }

        onSelect?(key)
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }

        let value = rows[row]
        let name = NSTextField(labelWithString: value.title)
        name.font = value.selectable ? .systemFont(ofSize: 12) : .boldSystemFont(ofSize: 12)
        name.textColor = value.colour; name.lineBreakMode = .byTruncatingMiddle
        let detail = NSTextField(labelWithString: value.detail)
        detail.font = .systemFont(ofSize: 10); detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingMiddle
        let stack = NSStackView(views: [name, detail]); stack.orientation = .vertical
        stack.alignment = .leading; stack.spacing = 2
        let cell = GitStatusCell(name: name, detail: detail, colour: value.colour)
        gitPin(stack, to: cell, inset: 4)
        cell.toolTip = value.title + "\n" + value.detail
        cell.setAccessibilityLabel(value.title + " " + value.detail)

        return cell
    }
    @objc func openSelected(_ sender: Any?) {
        if let key = selectedKey {
            if let onOpen { onOpen(key) } else { onSelect?(key) }
        }
    }
}

@MainActor
final class GitListTable: NSTableView {
    var openSelection: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 { openSelection?(); return }
        super.keyDown(with: event)
    }
}

@MainActor
private final class GitStatusCell: NSTableCellView {
    private let name: NSTextField
    private let detail: NSTextField
    private let colour: NSColor
    init(name: NSTextField, detail: NSTextField, colour: NSColor) {
        self.name = name; self.detail = detail; self.colour = colour
        super.init(frame: .zero)
        textField = name
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            name.textColor = backgroundStyle == .emphasized ? .alternateSelectedControlTextColor : colour
            detail.textColor = backgroundStyle == .emphasized ? .alternateSelectedControlTextColor : .secondaryLabelColor
        }
    }
}

@MainActor
func gitPin(_ child: NSView, to parent: NSView, inset: CGFloat = 0) {
    child.translatesAutoresizingMaskIntoConstraints = false
    parent.addSubview(child)
    NSLayoutConstraint.activate([
        child.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: inset),
        child.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -inset),
        child.topAnchor.constraint(equalTo: parent.topAnchor, constant: inset),
        child.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -inset)
    ])
}

@MainActor
func gitStack(_ views: [NSView], vertical: Bool = true) -> NSStackView {
    let result = NSStackView(views: views)
    result.orientation = vertical ? .vertical : .horizontal
    result.alignment = vertical ? .leading : .centerY
    result.spacing = 8
    for view in views where vertical { view.widthAnchor.constraint(equalTo: result.widthAnchor).isActive = true }

    return result
}
