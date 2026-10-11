import Foundation
import IDEDomain

/// Project-local ordering and selection. Paths and document lifetimes belong to the caller.
@MainActor
public final class DocumentTabs {
    public private(set) var order: [DocumentID] = []
    public private(set) var selected: DocumentID?
    private var observers: [UUID: () -> Void] = [:]

    public init() {}

    public func open(_ id: DocumentID) {
        if !order.contains(id) { order.append(id) }
        selected = id
        changed()
    }

    public func select(_ id: DocumentID) {
        guard order.contains(id), selected != id else { return }

        selected = id
        changed()
    }

    public func remove(_ id: DocumentID) {
        guard let index = order.firstIndex(of: id) else { return }

        order.remove(at: index)
        if selected == id { selected = order.isEmpty ? nil : order[min(index, order.count - 1)] }
        changed()
    }

    /// An insertion index in the current order, including the position after the final tab.
    public func move(_ id: DocumentID, to insertionIndex: Int) {
        guard let old = order.firstIndex(of: id), (0...order.count).contains(insertionIndex) else { return }

        let destination = insertionIndex > old ? insertionIndex - 1 : insertionIndex
        guard destination != old else { return }

        order.remove(at: old)
        order.insert(id, at: destination)
        changed()
    }

    @discardableResult
    public func subscribe(_ observer: @escaping () -> Void) -> UUID {
        let id = UUID()
        observers[id] = observer

        return id
    }

    public func unsubscribe(_ id: UUID) { observers[id] = nil }

    private func changed() {
        for observer in Array(observers.values) { observer() }
    }
}
