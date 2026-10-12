import AppKit

public enum WorkspaceNotificationKind: String, Sendable {
    case information, success, warning, error
}

/// Explicit caller-owned actions. The card does not infer commands from text or URLs.
@MainActor
public struct WorkspaceNotificationAction {
    public let title: String
    public let perform: () -> Void

    public init(title: String, perform: @escaping () -> Void) {
        self.title = title
        self.perform = perform
    }
}

@MainActor
public struct WorkspaceNotification {
    public let id: String
    public let kind: WorkspaceNotificationKind
    public let title: String
    public let message: String
    public let actions: [WorkspaceNotificationAction]

    public init(
        id: String = UUID().uuidString,
        kind: WorkspaceNotificationKind = .information,
        title: String,
        message: String = "",
        actions: [WorkspaceNotificationAction] = []
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.message = message
        self.actions = actions
    }
}

/// A bounded, in-memory collection scoped to its host window. No service or persistence.
@MainActor
public final class WorkspaceNotifications {
    public private(set) var items: [WorkspaceNotification] = []
    private var observers: [UUID: () -> Void] = [:]
    public let capacity: Int

    public init(capacity: Int = 5) {
        self.capacity = max(1, capacity)
    }

    /// Repeated IDs update in place, preserving keyboard focus and the stack order.
    public func post(_ item: WorkspaceNotification) {
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index] = item
        } else {
            items.append(item)
            if items.count > capacity { items.removeFirst(items.count - capacity) }
        }

        changed()
    }

    public func dismiss(_ id: String) {
        guard items.contains(where: { $0.id == id }) else { return }

        items.removeAll { $0.id == id }
        changed()
    }

    public func removeAll() {
        guard !items.isEmpty else { return }

        items = []
        changed()
    }

    @discardableResult
    public func subscribe(_ observer: @escaping () -> Void) -> UUID {
        let id = UUID()
        observers[id] = observer

        return id
    }

    public func unsubscribe(_ id: UUID) { observers[id] = nil }
    private func changed() { for observer in Array(observers.values) { observer() } }
}
