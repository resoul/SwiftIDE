import Foundation
@testable import IDEApplication
import Testing

private func file(_ json: String) -> ConfigurationFile { .present(Data(json.utf8)) }

private let release = file(#"{"swiftPM": {"configuration": "release"}}"#)
private let debug = file(#"{"swiftPM": {"configuration": "debug"}}"#)
private let other = file(#"{"backgroundIndexing": false}"#)

// MARK: Which configuration the server uses

@Test
func withNoFileTheServersDefaultIsInheritedNotSelected() {
    #expect(BuildConfigurationSetting.resolve(project: .absent, user: [], trust: .undecided) == .inherited("debug"))
}

@Test
func aTrustedProjectsFileSelectsTheConfiguration() {
    #expect(BuildConfigurationSetting.resolve(project: release, user: [], trust: .granted) == .selected("release"))
}

@Test
func aRefusedProjectsFileIsIgnoredAsTheServerIgnoresIt() {
    #expect(BuildConfigurationSetting.resolve(project: release, user: [], trust: .refused) == .inherited("debug"))
    #expect(BuildConfigurationSetting.resolve(project: release, user: [debug, release], trust: .refused) == .inherited("release"), "what the user's own files say still holds")
}

@Test
func whileTheDecisionIsAwaitedWhatTheServerWillDoIsUnknown() {
    #expect(BuildConfigurationSetting.resolve(project: release, user: [], trust: .undecided) == .unknown)
}

@Test
func aProjectFileThatSaysNothingOfTheConfigurationDoesNotDependOnTrust() {
    for trust in [ConfigurationTrust.undecided, .granted, .refused] {
        #expect(BuildConfigurationSetting.resolve(project: other, user: [release], trust: trust) == .inherited("release"))
    }
}

@Test
func theUsersFilesComeInTheServersOrderAndTheProjectsFileOverridesThem() {
    #expect(BuildConfigurationSetting.resolve(project: .absent, user: [release, .absent, debug], trust: .undecided) == .inherited("debug"), "a later file overrides an earlier")
    #expect(BuildConfigurationSetting.resolve(project: debug, user: [release], trust: .granted) == .selected("debug"))
}

@Test
func aFileThatCannotBeConfirmedMakesTheValueUnknownNotTheDefault() {
    #expect(BuildConfigurationSetting.resolve(project: .absent, user: [file("{ not json")], trust: .granted) == .unknown)
    #expect(BuildConfigurationSetting.resolve(project: .absent, user: [.unreadable], trust: .granted) == .unknown)
    #expect(BuildConfigurationSetting.resolve(project: file("{ not json"), user: [], trust: .granted) == .unknown)
    #expect(BuildConfigurationSetting.resolve(project: file(#"{"swiftPM": {"configuration": "fast"}}"#), user: [], trust: .granted) == .unknown, "a value the server has no meaning for")
    #expect(BuildConfigurationSetting.resolve(project: file(#"{"swiftPM": {"configuration": 3}}"#), user: [], trust: .granted) == .unknown)
    #expect(BuildConfigurationSetting.resolve(project: file(#"{"swiftPM": []}"#), user: [], trust: .granted) == .unknown)
}

@Test
func aProjectFileNobodyObeysNeedNotBeReadable() {
    #expect(BuildConfigurationSetting.resolve(project: .unreadable, user: [], trust: .refused) == .inherited("debug"))
}

@Test
func theValueIsReadableFromAKnownSettingOnly() {
    #expect(BuildConfigurationSetting.selected("release").value == "release")
    #expect(BuildConfigurationSetting.inherited("debug").value == "debug")
    #expect(BuildConfigurationSetting.unknown.value == nil)
}
