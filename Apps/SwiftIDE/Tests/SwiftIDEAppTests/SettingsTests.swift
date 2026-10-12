import AppKit
import IDEApplication
import IDETestSupport
import Testing
import WorkspaceUI
@testable import SwiftIDE

extension NativeAppTests {
    @Suite(.serialized)
    @MainActor
    struct SettingsTests {
        private func defaults() throws -> UserDefaults {
            try #require(UserDefaults(suiteName: "SwiftIDE.settings.tests.\(UUID())"))
        }

        @Test func theChoiceIsStoredAppliedAndRestoredAtLaunch() throws {
            let defaults = try defaults()
            var applied: [String?] = []
            let first = AppearanceSettings(defaults: defaults, apply: { applied.append($0?.name.rawValue) })
            #expect(first.preference == .system)
            first.preference = .dark
            first.preference = .system
            first.preference = .light
            #expect(applied == [NSAppearance.Name.darkAqua.rawValue, nil, NSAppearance.Name.aqua.rawValue])
            applied = []
            let relaunched = AppearanceSettings(defaults: defaults, apply: { applied.append($0?.name.rawValue) })
            relaunched.applyStored()
            #expect(relaunched.preference == .light)
            #expect(applied == [NSAppearance.Name.aqua.rawValue])
        }

        @Test func anUnknownStoredValueMeansTheSystemAppearance() throws {
            let defaults = try defaults()
            defaults.set("sepia", forKey: "settings.appearance.v1")
            #expect(AppearanceSettings(defaults: defaults, apply: { _ in }).preference == .system)
        }

        @Test func settingsOpenFromTheMenuShowTheStoredChoiceAndApplyANewOne() async throws {
            _ = NSApplication.shared
            let defaults = try defaults()
            var applied: [NSAppearance?] = []
            let settings = AppearanceSettings(defaults: defaults, apply: { applied.append($0) })
            settings.preference = .dark
            applied = []
            let app = AppDelegate(composition: AppCompositionRoot(
                recoveryStore: MemoryRecoveryStore(),
                recentStore: MemoryRecentProjectsStore(),
                appearance: settings
            ))
            MainMenu.install()
            defer { app.settingsWindow?.close() }
            let item = try #require(NSApp.mainMenu?.items.first?.submenu?.items.first)
            #expect(item.title == "Settings…" && item.keyEquivalent == ",")
            #expect(item.action == #selector(AppDelegate.showSettings(_:)))
            app.showSettings(nil)
            let window = try #require(app.settingsWindow)
            #expect(window.window?.isVisible == true && window.window?.title == "Settings")
            #expect(window.content.appearancePreference == .dark)
            window.content.appearanceControl.selectedSegment = 1
            window.content.appearanceChosen(nil)
            #expect(settings.preference == .light)
            #expect(applied.map { $0?.name } == [.aqua])
            app.showSettings(nil)
            #expect(app.settingsWindow === window, "one Settings window")
        }

        @Test func noPreviewWindowOrSampleViewCommandsRemain() throws {
            _ = NSApplication.shared
            MainMenu.install()
            let titles = (NSApp.mainMenu?.items ?? []).flatMap { $0.submenu?.items.map(\.title) ?? [] }
            #expect(!titles.contains { $0.contains("Preview") })
        }
    }
}
