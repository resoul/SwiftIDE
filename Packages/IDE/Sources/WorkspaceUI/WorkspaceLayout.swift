import Foundation

/// A stable registered tool. Built-ins keep their original integer persistence IDs.
public struct WorkspaceTool: RawRepresentable, Codable, Hashable, Sendable, CaseIterable {
    public enum Zone: String, Codable, Hashable, Sendable { case left, right, bottom }
    public let rawValue: Int
    public let title: String
    public let symbol: String
    public let zone: Zone

    public static let files = Self(builtin: 0, title: "Files", symbol: "folder", zone: .left)
    public static let search = Self(builtin: 1, title: "Search", symbol: "magnifyingglass", zone: .left)
    public static let sourceControl = Self(
        builtin: 2,
        title: "Source Control",
        symbol: "arrow.triangle.branch",
        zone: .left
    )
    public static let terminal = Self(builtin: 3, title: "Terminal", symbol: "terminal", zone: .bottom)
    public static let build = Self(builtin: 4, title: "Build Output", symbol: "hammer", zone: .bottom)
    public static let problems = Self(builtin: 5, title: "Problems", symbol: "exclamationmark.circle", zone: .bottom)
    public static let assistant = Self(
        builtin: 6,
        title: "Assistant",
        symbol: "bubble.left.and.bubble.right",
        zone: .right
    )
    public static let structure = Self(builtin: 7, title: "Structure", symbol: "list.bullet.indent", zone: .right)
    public static let inspector = Self(builtin: 8, title: "Inspector", symbol: "slider.horizontal.3", zone: .right)
    public static let allCases: [Self] = [
        .files,
        .search,
        .sourceControl,
        .terminal,
        .build,
        .problems,
        .assistant,
        .structure,
        .inspector
    ]

    /// IDs >= 100 are reserved for caller-supplied tools, independent of their panel contents.
    public init(id: Int, title: String, symbol: String, zone: Zone) {
        precondition(id >= 100, "Custom tool IDs must not collide with built-ins")
        self.init(builtin: id, title: title, symbol: symbol, zone: zone)
    }

    private init(builtin: Int, title: String, symbol: String, zone: Zone) {
        rawValue = builtin
        self.title = title
        self.symbol = symbol
        self.zone = zone
    }

    public init?(rawValue: Int) {
        guard let tool = Self.allCases.first(where: { $0.rawValue == rawValue }) else { return nil }

        self = tool
    }

    private enum CodingKeys: String, CodingKey { case id, title, symbol, zone }

    public init(from decoder: any Decoder) throws {
        if let raw = try? decoder.singleValueContainer().decode(Int.self), let tool = Self(rawValue: raw) {
            self = tool

            return
        }

        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decode(Int.self, forKey: .id)
        guard id >= 100 else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "Invalid custom tool ID")
        }

        self.init(
            builtin: id,
            title: try c.decode(String.self, forKey: .title),
            symbol: try c.decode(String.self, forKey: .symbol),
            zone: try c.decode(Zone.self, forKey: .zone)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        if rawValue < 100 {
            var c = encoder.singleValueContainer()
            try c.encode(rawValue)

            return
        }

        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(rawValue, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(symbol, forKey: .symbol)
        try c.encode(zone, forKey: .zone)
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
        result.left = available.first { $0.rawValue == left?.rawValue && $0.zone == .left }
        result.right = available.first { $0.rawValue == right?.rawValue && $0.zone == .right }
        result.bottom = available.first { $0.rawValue == bottom?.rawValue && $0.zone == .bottom }
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
        precondition(Set(available.map(\.rawValue)).count == available.count, "Tool IDs must be unique")
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
