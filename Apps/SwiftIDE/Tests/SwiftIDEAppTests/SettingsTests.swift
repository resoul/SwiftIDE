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

        @Test func theEditorDisplayChoicesAreStoredNotifyOnChangeAndSurviveARelaunch() throws {
            let defaults = try defaults()
            let settings = EditorDisplaySettings(defaults: defaults)
            #expect(!settings.showsTabs && !settings.showsSpaces)
            var changes = 0
            let id = settings.subscribe { changes += 1 }
            settings.showsTabs = true
            settings.showsTabs = true
            settings.showsSpaces = true
            #expect(changes == 2, "setting the same value again tells nobody")
            settings.unsubscribe(id)
            settings.showsSpaces = false
            #expect(changes == 2)
            let relaunched = EditorDisplaySettings(defaults: defaults)
            #expect(relaunched.showsTabs && !relaunched.showsSpaces)
        }

        @Test func settingsAndTheViewMenuChangeWhatEveryEditorMarks() async throws {
            _ = NSApplication.shared
            let display = EditorDisplaySettings(defaults: try defaults())
            let composition = AppCompositionRoot(
                recoveryStore: MemoryRecoveryStore(),
                recentStore: MemoryRecentProjectsStore(),
                appearance: AppearanceSettings(defaults: try defaults(), apply: { _ in }),
                editorDisplay: display
            )
            let app = AppDelegate(composition: composition)
            MainMenu.install()
            let document = composition.makeUntitledWindow()
            document.showWindow(nil)
            defer {
                app.settingsWindow?.close()
                document.close()
            }
            let view = try #require(document.window?.contentView?.firstDescendant(ofType: NSTextView.self))
            #expect(view.whitespaceMarkFrames.isEmpty)
            view.string = ""
            view.insertText("\ta  b", replacementRange: NSRange(location: 0, length: 0))

            let viewMenu = try #require(NSApp.mainMenu?.items.first { $0.submenu?.title == "View" }?.submenu)
            let tabs = try #require(viewMenu.items.first { $0.title == "Show Tabs" })
            let spaces = try #require(viewMenu.items.first { $0.title == "Show Spaces" })
            #expect(app.validateMenuItem(tabs) && tabs.state == .off)
            app.toggleShowTabs(nil)
            #expect(display.showsTabs && app.validateMenuItem(tabs) && tabs.state == .on)
            view.window?.layoutIfNeeded()
            view.window?.displayIfNeeded()
            #expect(view.whitespaceMarkFrames.map(\.isTab) == [true])

            app.showSettings(nil)
            let settings = try #require(app.settingsWindow)
            #expect(settings.content.showsTabs && !settings.content.showsSpaces)
            settings.content.spacesBox.state = .on
            settings.content.displayChosen(nil)
            #expect(display.showsSpaces && app.validateMenuItem(spaces) && spaces.state == .on)
            #expect(view.whitespaceMarkFrames.count == 3)
            app.toggleShowTabs(nil)
            #expect(
                !settings.content.showsTabs && settings.content.tabsBox.state == .off,
                "the open window follows the menu"
            )
            #expect(view.whitespaceMarkFrames.allSatisfy { !$0.isTab })
        }

        @Test func noPreviewWindowOrSampleViewCommandsRemain() throws {
            _ = NSApplication.shared
            MainMenu.install()
            let titles = (NSApp.mainMenu?.items ?? []).flatMap { $0.submenu?.items.map(\.title) ?? [] }
            #expect(!titles.contains { $0.contains("Preview") })
        }
    }
}

private extension NSView {
    func firstDescendant<T: NSView>(ofType type: T.Type) -> T? {
        if let match = self as? T { return match }

        for child in subviews { if let found = child.firstDescendant(ofType: type) { return found } }

        return nil
    }
}
