import Foundation

public enum WorkspaceTool: Int, Codable, CaseIterable, Sendable {
    case files, search, sourceControl, terminal, build, problems, assistant, structure, inspector
    public enum Zone: Sendable { case left, right, bottom }
    public var zone: Zone {
        switch self {
        case .files, .search, .sourceControl: .left
        case .assistant, .structure, .inspector: .right
        case .terminal, .build, .problems: .bottom
        }
    }
    public var title: String {
        switch self {
        case .files: "Files"
        case .search: "Search"
        case .sourceControl: "Source Control"
        case .terminal: "Terminal"
        case .build: "Build Output"
        case .problems: "Problems"
        case .assistant: "Assistant"
        case .structure: "Structure"
        case .inspector: "Inspector"
        }
    }
    public var symbol: String {
        switch self {
        case .files: "folder"
        case .search: "magnifyingglass"
        case .sourceControl: "arrow.triangle.branch"
        case .terminal: "terminal"
        case .build: "hammer"
        case .problems: "exclamationmark.circle"
        case .assistant: "bubble.left.and.bubble.right"
        case .structure: "list.bullet.indent"
        case .inspector: "slider.horizontal.3"
        }
    }
}

public struct WorkspaceLayout: Codable, Equatable, Sendable {
    public var left: WorkspaceTool? = .files
    public var right: WorkspaceTool?
    public var bottom: WorkspaceTool?
    public var leftWidth: Double = 260
    public var rightWidth: Double = 300
    public var bottomHeight: Double = 220

    public init() {}

    public mutating func toggle(_ tool: WorkspaceTool) {
        switch tool.zone {
        case .left: left = left == tool ? nil : tool
        case .right: right = right == tool ? nil : tool
        case .bottom: bottom = bottom == tool ? nil : tool
        }
    }
    public func contains(_ tool: WorkspaceTool) -> Bool {
        left == tool || right == tool || bottom == tool
    }

    func validated(available: Set<WorkspaceTool>) -> Self {
        var result = self
        if let left, left.zone != .left || !available.contains(left) { result.left = nil }
        if let right, right.zone != .right || !available.contains(right) { result.right = nil }
        if let bottom, bottom.zone != .bottom || !available.contains(bottom) { result.bottom = nil }
        result.leftWidth = leftWidth.isFinite ? min(440, max(200, leftWidth)) : 260
        result.rightWidth = rightWidth.isFinite ? min(480, max(240, rightWidth)) : 300
        result.bottomHeight = bottomHeight.isFinite ? min(380, max(140, bottomHeight)) : 220

        return result
    }
}

/// Shared by a project's browser and document tabs. Persistence belongs to the caller.
@MainActor
public final class WorkspaceLayoutState {
    public private(set) var layout: WorkspaceLayout
    public private(set) var isFocused = false
    public let available: Set<WorkspaceTool>
    public var onSave: ((WorkspaceLayout) -> Void)?
    public var persistentLayout: WorkspaceLayout { beforeFocus ?? layout }
    private var beforeFocus: WorkspaceLayout?
    private var observers: [UUID: () -> Void] = [:]

    public init(layout: WorkspaceLayout = .init(), available: Set<WorkspaceTool> = [.files]) {
        self.available = available
        self.layout = layout.validated(available: available)
    }

    public func select(_ tool: WorkspaceTool) {
        guard available.contains(tool) else { return }

        let wasFocused = isFocused
        restoreFocus()
        if wasFocused {
            switch tool.zone {
            case .left: layout.left = tool
            case .right: layout.right = tool
            case .bottom: layout.bottom = tool
            }
        } else {
            layout.toggle(tool)
        }

        changed()
    }

    public func toggleFocus() {
        if isFocused {
            restoreFocus()
        } else {
            beforeFocus = layout
            isFocused = true
            layout.left = nil
            layout.right = nil
            layout.bottom = nil
        }

        changed()
    }

    public func reset() {
        beforeFocus = nil
        isFocused = false
        layout = WorkspaceLayout().validated(available: available)
        changed()
    }

    /// Resizing a smaller window does not overwrite the preferred size saved for a larger one.
    public func resize(left: Double? = nil, right: Double? = nil, bottom: Double? = nil) {
        guard !isFocused else { return }

        var next = layout
        if let left { next.leftWidth = left }
        if let right { next.rightWidth = right }
        if let bottom { next.bottomHeight = bottom }
        next = next.validated(available: available)
        guard next != layout else { return }

        layout = next
        changed()
    }

    @discardableResult
    public func subscribe(_ observer: @escaping () -> Void) -> UUID {
        let id = UUID()
        observers[id] = observer

        return id
    }

    public func unsubscribe(_ id: UUID) { observers[id] = nil }

    private func restoreFocus() {
        if let beforeFocus { layout = beforeFocus }
        beforeFocus = nil
        isFocused = false
    }

    private func changed() {
        onSave?(beforeFocus ?? layout)
        for observer in Array(observers.values) { observer() }
    }
}
