import Foundation
import IDEApplication

/// What the user decided about projects' configuration, kept between runs by canonical root. Only
/// the user's answer writes here; a repository has no way to declare itself trusted.
@MainActor
final class UserDefaultsProjectTrustStore: ProjectTrustStore {
    private let defaults: UserDefaults
    private let key = "ProjectConfigurationTrust"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func decision(forRoot root: String) -> TrustDecision? {
        (defaults.dictionary(forKey: key) as? [String: String])?[root].flatMap(TrustDecision.init(rawValue:))
    }

    func record(_ decision: TrustDecision, forRoot root: String) {
        var all = (defaults.dictionary(forKey: key) as? [String: String]) ?? [:]
        all[root] = decision.rawValue
        defaults.set(all, forKey: key)
    }

    func forget(root: String) {
        var all = (defaults.dictionary(forKey: key) as? [String: String]) ?? [:]
        all.removeValue(forKey: root)
        defaults.set(all, forKey: key)
    }
}
