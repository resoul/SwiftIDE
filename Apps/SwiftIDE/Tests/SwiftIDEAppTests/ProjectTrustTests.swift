import AppKit
import IDEApplication
import Testing
@testable import SwiftIDE

extension NativeAppTests {
    struct ProjectTrustTests {
        @Test @MainActor func theDecisionsAboutProjectsAreKeptBetweenRunsByRoot() {
            let suite = "SwiftIDE.tests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }

            let store = UserDefaultsProjectTrustStore(defaults: defaults)
            #expect(store.decision(forRoot: "/w/a") == nil, "undecided is not a decision")
            store.record(.granted, forRoot: "/w/a")
            store.record(.refused, forRoot: "/w/b")
            let later = UserDefaultsProjectTrustStore(defaults: defaults)   // the next run
            #expect(later.decision(forRoot: "/w/a") == .granted && later.decision(forRoot: "/w/b") == .refused)
            later.forget(root: "/w/a")
            #expect(UserDefaultsProjectTrustStore(defaults: defaults).decision(forRoot: "/w/a") == nil)
            #expect(UserDefaultsProjectTrustStore(defaults: defaults).decision(forRoot: "/w/b") == .refused)
        }

        @Test @MainActor func anUnknownStoredValueIsNotTakenForTrust() {
            let suite = "SwiftIDE.tests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }

            defaults.set(["/w/a": "yes please"], forKey: "ProjectConfigurationTrust")
            #expect(UserDefaultsProjectTrustStore(defaults: defaults).decision(forRoot: "/w/a") == nil)
        }

        @Test @MainActor func theProjectMenuOffersToAllowRefuseAndAskAgain() throws {
            _ = NSApplication.shared
            MainMenu.install()
            let project = try #require(NSApp.mainMenu?.items.first { $0.submenu?.title == "Project" }?.submenu)
            let items = project.items.filter { !$0.isSeparatorItem }
            #expect(items.map(\.title) == ["Allow Project Configuration", "Don't Allow Project Configuration", "Ask About Project Configuration Again"])
            #expect(items.map(\.action) == [
                #selector(WorkspaceWindowController.allowProjectConfiguration(_:)),
                #selector(WorkspaceWindowController.disallowProjectConfiguration(_:)),
                #selector(WorkspaceWindowController.askAboutProjectConfigurationAgain(_:)),
            ])
        }
    }

    struct OpenFolderMenuTests {
        @Test @MainActor func theFileMenuOffersToOpenAndToCloseFolders() throws {
            _ = NSApplication.shared
            MainMenu.install()
            let file = try #require(NSApp.mainMenu?.items.first { $0.submenu?.title == "File" }?.submenu)

            let open = try #require(file.items.first { $0.title == "Open Folder…" })
            #expect(open.action == #selector(AppDelegate.openFolder(_:)))
            #expect(open.keyEquivalent == "O" && open.keyEquivalentModifierMask.contains(.command))

            let close = try #require(file.items.first { $0.title == "Close Opened Folders" })
            #expect(close.action == #selector(AppDelegate.closeOpenedFolders(_:)))
        }
    }
}
