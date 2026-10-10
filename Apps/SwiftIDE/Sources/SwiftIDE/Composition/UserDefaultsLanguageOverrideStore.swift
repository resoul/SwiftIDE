import Foundation
import IDEApplication
import IDEDomain

/// The languages the user chose for files, kept between runs (until there are workspaces to keep
/// them in). Nothing in the file or in the document changes.
@MainActor
final class UserDefaultsLanguageOverrideStore: LanguageOverrideStore {
    private let defaults: UserDefaults
    private let key = "DocumentLanguageOverrides"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func override(forPath path: String) -> DocumentLanguage? {
        (defaults.dictionary(forKey: key) as? [String: String])?[path].flatMap(DocumentLanguage.init(rawValue:))
    }

    func setOverride(_ language: DocumentLanguage?, forPath path: String) {
        var all = (defaults.dictionary(forKey: key) as? [String: String]) ?? [:]
        all[path] = language?.rawValue
        defaults.set(all, forKey: key)
    }
}
