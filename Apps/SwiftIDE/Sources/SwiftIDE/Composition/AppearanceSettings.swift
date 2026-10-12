import AppKit
import WorkspaceUI

/// The theme the user chose in Settings. It is applied to the whole application, so every window follows it.
@MainActor
final class AppearanceSettings {
    private static let key = "settings.appearance.v1"
    private let defaults: UserDefaults
    private let apply: (NSAppearance?) -> Void

    init(
        defaults: UserDefaults = .standard,
        apply: @escaping (NSAppearance?) -> Void = { NSApp.appearance = $0 }
    ) {
        self.defaults = defaults
        self.apply = apply
    }

    var preference: AppearancePreference {
        get { defaults.string(forKey: Self.key).flatMap(AppearancePreference.init(rawValue:)) ?? .system }
        set {
            defaults.set(newValue.rawValue, forKey: Self.key)
            apply(newValue.appearance)
        }
    }

    /// At launch, before any window is shown.
    func applyStored() { apply(preference.appearance) }
}
