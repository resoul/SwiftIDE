import AppKit
import IDEApplication
import IDEDomain
import Testing
@testable import SwiftIDE

struct LanguageChoiceTests {
    @Test @MainActor func theChoiceOfLanguageIsKeptBetweenRunsByPath() {
        let suite = "SwiftIDE.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        UserDefaultsLanguageOverrideStore(defaults: defaults).setOverride(.objectiveCPP, forPath: "/w/a.h")
        let later = UserDefaultsLanguageOverrideStore(defaults: defaults)   // the next run
        #expect(later.override(forPath: "/w/a.h") == .objectiveCPP)
        #expect(later.override(forPath: "/w/b.h") == nil)
        later.setOverride(nil, forPath: "/w/a.h")
        #expect(UserDefaultsLanguageOverrideStore(defaults: defaults).override(forPath: "/w/a.h") == nil)
    }

    @Test @MainActor func editLanguageMenuOffersAutomaticAndEveryLanguage() throws {
        _ = NSApplication.shared
        MainMenu.install()
        let edit = try #require(NSApp.mainMenu?.items.first { $0.submenu?.title == "Edit" }?.submenu)
        let language = try #require(edit.items.first { $0.title == "Language" }?.submenu)
        let titles = language.items.filter { !$0.isSeparatorItem }.map(\.title)
        #expect(titles == ["Automatic", "Swift", "C", "C++", "Objective-C", "Objective-C++", "Plain Text"])
        #expect(language.items.filter { !$0.isSeparatorItem }.allSatisfy { $0.action == #selector(WorkspaceWindowController.selectLanguage(_:)) })
        let chosen = language.items.compactMap { $0.representedObject as? String }
        #expect(chosen == DocumentLanguage.allCases.map(\.rawValue), "each item names its language; Automatic names none")
    }
}
