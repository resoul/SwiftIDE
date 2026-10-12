import AppKit
import IDEDomain
import IconUI

@MainActor
final class ChatMessageRow: NSTableRowView {
    private let surface = ChatSurface()
    private let role = NSTextField(labelWithString: "")
    private let context = NSTextField(labelWithString: "")
    private let copy = NSButton(title: "Copy", target: nil, action: nil)
    private var blocks: [UUID: ChatBlockView] = [:]
    private(set) var message: AgentMessage?
    private var collapsed: Set<UUID> = []
    var copyText: ((String) -> Void)?
    var toggleTool: ((UUID) -> Void)?
    override var isFlipped: Bool { true }
    override var isEmphasized: Bool { get { false } set {} }

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(surface)
        role.font = .systemFont(ofSize: 11, weight: .semibold)
        role.textColor = .secondaryLabelColor
        context.font = .systemFont(ofSize: 10)
        context.textColor = .secondaryLabelColor
        context.lineBreakMode = .byTruncatingMiddle
        copy.font = .systemFont(ofSize: 10)
        copy.isBordered = false
        copy.target = self
        copy.action = #selector(copyMessage(_:))
        surface.wantsLayer = true
        surface.layer?.cornerRadius = 12
        surface.addSubview(role)
        surface.addSubview(copy)
        surface.addSubview(context)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func present(_ message: AgentMessage, collapsed: Set<UUID>) {
        self.message = message
        self.collapsed = collapsed
        let active = Set(message.blocks.map(\.id))
        for id in Array(blocks.keys) where !active.contains(id) {
            blocks.removeValue(forKey: id)?.removeFromSuperview()
        }
        for block in message.blocks {
            let current = blocks[block.id] ?? ChatBlockView()
            if blocks[block.id] == nil {
                surface.addSubview(current)
                blocks[block.id] = current
            }

            current.toggle = { [weak self] in self?.toggleTool?(block.id) }
            current.copyText = { [weak self] in self?.copyText?($0) }
            current.present(block, collapsed: collapsed.contains(block.id))
        }
        let suffix: String
        switch message.status {
        case .streaming: suffix = " · responding…"
        case .cancelled: suffix = " · stopped"
        case .failed: suffix = " · interrupted"
        case .complete: suffix = ""
        }
        role.stringValue = (message.role == .user ? "You" : "Agent") + suffix
        context.stringValue = message.contexts.map { $0.name + " · v\($0.version)" }.joined(separator: "  ·  ")
        context.toolTip = message.contexts.map { $0.path + " · v\($0.version)" }.joined(separator: "\n")
        context.isHidden = message.contexts.isEmpty
        copy.isHidden = message.blocks.isEmpty
        needsLayout = true
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard let message else { return }

        let width = Self.contentWidth(message, width: bounds.width)
        let x = message.role == .user ? bounds.width - width - 12 : 12
        surface.frame = NSRect(x: x, y: 4, width: width, height: bounds.height - 8)
        surface.fillColor = message.role == .user ? NSColor.systemBlue.withAlphaComponent(0.12) : .clear
        role.frame = NSRect(x: 12, y: 8, width: max(1, width - 72), height: 17)
        copy.frame = NSRect(x: width - 53, y: 7, width: 42, height: 18)
        var y: CGFloat = 31
        if !message.contexts.isEmpty {
            context.frame = NSRect(x: 12, y: y, width: width - 24, height: 16)
            y += 22
        }

        for block in message.blocks {
            let height = ChatBlockView.height(block, width: width - 24, collapsed: collapsed.contains(block.id))
            blocks[block.id]?.frame = NSRect(x: 12, y: y, width: width - 24, height: height)
            y += height + 10
        }
    }

    static func contentWidth(_ message: AgentMessage, width: CGFloat) -> CGFloat {
        let available = max(60, width - 24)
        guard message.role == .user else { return available }

        let natural = NSAttributedString(string: message.plainText, attributes: ChatTextView.attributes()).size()
            .width + 28

        return min(available * 0.94, max(140, min(natural, 460)))
    }

    static func height(_ message: AgentMessage, width: CGFloat, collapsed: Set<UUID>) -> CGFloat {
        let content = contentWidth(message, width: width) - 24

        return 49 + (message.contexts.isEmpty ? 0 : 22) + message.blocks.reduce(0) {
            $0 + ChatBlockView.height($1, width: content, collapsed: collapsed.contains($1.id)) + 10
        }
    }

    @objc private func copyMessage(_ sender: Any?) {
        if let message { copyText?(message.plainText) }
    }

    func textView(block id: UUID) -> NSTextView? { blocks[id]?.text }

    func blockView(id: UUID) -> ChatBlockView? { blocks[id] }
}

@MainActor
final class ChatBlockView: ChatSurface {
    let text = ChatTextView()
    private let language = NSTextField(labelWithString: "")
    let copy = NSButton(title: "Copy code", target: nil, action: nil)
    let disclosure = NSButton(title: "", target: nil, action: nil)
    private var block: AgentBlock?
    private var collapsed = false
    var copyText: ((String) -> Void)?
    var toggle: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 8
        language.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
        language.textColor = .secondaryLabelColor
        language.lineBreakMode = .byTruncatingTail
        copy.font = .systemFont(ofSize: 10)
        copy.isBordered = false
        copy.target = self
        copy.action = #selector(copyCode(_:))
        disclosure.isBordered = false
        disclosure.alignment = .left
        disclosure.font = .systemFont(ofSize: 11, weight: .medium)
        disclosure.target = self
        disclosure.action = #selector(toggleDetail(_:))
        for subview in [text, language, copy, disclosure] { addSubview(subview) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func present(_ block: AgentBlock, collapsed: Bool) {
        self.block = block
        self.collapsed = collapsed
        switch block.content {
        case .text(let value):
            text.present(value)
            language.isHidden = true
            copy.isHidden = true
            disclosure.isHidden = true
            text.isHidden = false
            text.setAccessibilityLabel("Message text")
        case .code(let name, let value):
            text.present(value, monospaced: true)
            language.stringValue = name.uppercased()
            language.isHidden = false
            copy.isHidden = false
            disclosure.isHidden = true
            text.isHidden = false
            text.setAccessibilityLabel("Code block, " + name)
        case .tool(let tool):
            text.present(tool.detail)
            language.isHidden = true
            copy.isHidden = true
            disclosure.isHidden = false
            text.isHidden = collapsed
            disclosure.title = (collapsed ? "▸ " : "▾ ") + tool.title + " · " + tool.state.rawValue
            disclosure.image = (tool.state == .succeeded ? TablerIcon.circleCheck : .terminal2).image()
            disclosure.imagePosition = .imageLeading
            disclosure.contentTintColor = tool.state == .succeeded ? .systemGreen : .secondaryLabelColor
            disclosure.toolTip = tool.title + "\n" + tool.detail
            disclosure.setAccessibilityLabel(tool.title + ", " + tool.state.rawValue + (collapsed
                    ? ", collapsed"
                    : ", expanded"))
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard let block else { return }

        switch block.content {
        case .text:
            fillColor = .clear
            text.frame = bounds
        case .code:
            fillColor = NSColor.labelColor.withAlphaComponent(0.05)
            language.frame = NSRect(x: 10, y: 9, width: max(1, bounds.width - 86), height: 15)
            copy.frame = NSRect(x: bounds.width - 74, y: 6, width: 66, height: 20)
            text.frame = NSRect(x: 10, y: 33, width: max(1, bounds.width - 20), height: bounds.height - 40)
        case .tool:
            fillColor = NSColor.labelColor.withAlphaComponent(0.035)
            disclosure.frame = NSRect(x: 8, y: 7, width: max(1, bounds.width - 16), height: 22)
            text.frame = NSRect(x: 12, y: 36, width: max(1, bounds.width - 24), height: max(1, bounds.height - 43))
        }
    }

    static func height(_ block: AgentBlock, width: CGFloat, collapsed: Bool) -> CGFloat {
        switch block.content {
        case .text(let text): ChatTextView.height(text, width: width)
        case .code(_, let text): 43 + ChatTextView.height(text, width: width - 20, monospaced: true)
        case .tool(let tool): collapsed ? 36 : 47 + ChatTextView.height(tool.detail, width: width - 24)
        }
    }

    @objc func copyCode(_ sender: Any?) {
        if case .code(_, let value) = block?.content { copyText?(value) }
    }

    @objc private func toggleDetail(_ sender: Any?) { toggle?() }
}
