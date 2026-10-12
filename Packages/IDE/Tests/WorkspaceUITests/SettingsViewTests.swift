import AppKit
import Testing
@testable import WorkspaceUI

@Suite(.serialized) @MainActor
struct SettingsViewTests {
    @Test func theControlShowsTheCurrentChoiceAndReportsOnlyChanges() {
        _ = NSApplication.shared
        let controller = SettingsViewController(appearance: .dark)
        var reported: [AppearancePreference] = []
        controller.onAppearanceChange = { reported.append($0) }
        _ = controller.view
        #expect(controller.appearanceControl.segmentCount == 3)
        #expect(controller.appearanceControl.selectedSegment == 2)
        controller.appearanceControl.selectedSegment = 2
        controller.appearanceChosen(nil)
        #expect(reported.isEmpty)
        controller.appearanceControl.selectedSegment = 1
        controller.appearanceChosen(nil)
        #expect(reported == [.light] && controller.appearancePreference == .light)
        controller.appearancePreference = .system
        #expect(controller.appearanceControl.selectedSegment == 0)
        #expect(reported == [.light], "setting it from the host is not a user choice")
    }

    @Test func systemFollowsMacOSAndTheOthersPinTheLook() {
        _ = NSApplication.shared
        #expect(AppearancePreference.system.appearance == nil)
        #expect(AppearancePreference.light.appearance?.name == .aqua)
        #expect(AppearancePreference.dark.appearance?.name == .darkAqua)
        #expect(AppearancePreference.allCases.map(\.title) == ["System", "Light", "Dark"])
    }
}
