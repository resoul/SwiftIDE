import Foundation

/// What the user chose to see in every editor: whether tabs and spaces are marked. Stored with the
/// application's other preferences; editors listen and redraw, none of them keeps its own copy.
@MainActor
final class EditorDisplaySettings {
    private static let tabsKey = "settings.editor.showTabs.v1"
    private static let spacesKey = "settings.editor.showSpaces.v1"
    private let defaults: UserDefaults
    private var observers: [UUID: () -> Void] = [:]

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var showsTabs: Bool {
        get { defaults.bool(forKey: Self.tabsKey) }
        set { change(Self.tabsKey, to: newValue, from: showsTabs) }
    }

    var showsSpaces: Bool {
        get { defaults.bool(forKey: Self.spacesKey) }
        set { change(Self.spacesKey, to: newValue, from: showsSpaces) }
    }

    /// `observer` runs after every change; the subscription ends with `unsubscribe`.
    @discardableResult
    func subscribe(_ observer: @escaping () -> Void) -> UUID {
        let id = UUID()
        observers[id] = observer

        return id
    }

    func unsubscribe(_ id: UUID) { observers[id] = nil }

    private func change(_ key: String, to value: Bool, from old: Bool) {
        guard value != old else { return }

        defaults.set(value, forKey: key)
        for observer in Array(observers.values) { observer() }
    }
}
