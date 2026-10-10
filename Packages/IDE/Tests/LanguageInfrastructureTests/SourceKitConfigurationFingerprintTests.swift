import Foundation
import IDEApplication
import Testing
@testable import LanguageInfrastructure

@Suite
struct SourceKitConfigurationFingerprintTests {
    private func file(_ text: String) -> ConfigurationFile { .present(Data(text.utf8)) }

    @Test
    func identicalInputsHaveTheSameFingerprint() {
        let user = [file(#"{"backgroundIndexing":true}"#), .absent]
        let project = file(#"{"swiftPM":{"swiftSDK":"sdk"}}"#)

        #expect(SourceKitConfigurationFingerprint.make(user: user, project: project, trust: .granted)
            == SourceKitConfigurationFingerprint.make(user: user, project: project, trust: .granted))
    }

    @Test
    func priorityOrderAndFileBoundariesMatter() {
        let a = file("a"), b = file("b"), ab = file("ab")
        let digest = SourceKitConfigurationFingerprint.make(user: [a, b], project: .absent, trust: .granted)

        #expect(digest != SourceKitConfigurationFingerprint.make(user: [b, a], project: .absent, trust: .granted))
        #expect(digest != SourceKitConfigurationFingerprint.make(user: [ab], project: .absent, trust: .granted))
        #expect(digest != SourceKitConfigurationFingerprint.make(user: [a], project: b, trust: .granted))
        #expect(SourceKitConfigurationFingerprint.make(user: [file("ab"), file("c")], project: .absent, trust: .granted)
            != SourceKitConfigurationFingerprint.make(user: [file("a"), file("bc")], project: .absent, trust: .granted))
    }

    @Test
    func missingUnreadableAndEmptyFilesAreDifferent() {
        let inputs: [ConfigurationFile] = [.absent, .unreadable, .present(Data())]
        let fingerprints = inputs.map { SourceKitConfigurationFingerprint.make(user: [$0], project: .absent, trust: .granted) }

        #expect(Set(fingerprints).count == inputs.count)
        let projects = inputs.map { SourceKitConfigurationFingerprint.make(user: [], project: $0, trust: .granted) }
        #expect(Set(projects).count == inputs.count)
    }

    @Test
    func refusedProjectFilesAreExcludedButUserFilesStillMatter() {
        let digest = SourceKitConfigurationFingerprint.make(user: [file("user")], project: .absent, trust: .refused)
        for project in [file("project"), file("changed"), .unreadable] {
            #expect(digest == SourceKitConfigurationFingerprint.make(user: [file("user")], project: project, trust: .refused))
        }
        #expect(digest != SourceKitConfigurationFingerprint.make(user: [file("changed user")], project: file("project"), trust: .refused))
    }

    @Test
    func pendingFilesAndTheirPermissionChangesAreNoticed() {
        let project = file(#"{"swiftPM":{"swiftSDK":"sdk"}}"#)
        let pending = SourceKitConfigurationFingerprint.make(user: [], project: project, trust: .undecided)

        #expect(pending != SourceKitConfigurationFingerprint.make(user: [], project: .absent, trust: .undecided))
        #expect(pending != SourceKitConfigurationFingerprint.make(user: [], project: file("changed"), trust: .undecided))
        #expect(pending != SourceKitConfigurationFingerprint.make(user: [], project: project, trust: .granted))
        #expect(pending != SourceKitConfigurationFingerprint.make(user: [], project: project, trust: .refused))
        #expect(SourceKitConfigurationFingerprint.make(user: [], project: .absent, trust: .undecided)
            == SourceKitConfigurationFingerprint.make(user: [], project: .absent, trust: .granted))
    }

    @Test
    func theWholeContentsMatterEvenWhenJSONCannotBeRead() {
        let before = SourceKitConfigurationFingerprint.make(user: [], project: file("{}"), trust: .granted)
        #expect(before != SourceKitConfigurationFingerprint.make(user: [], project: file("{ }\n"), trust: .granted))
        #expect(SourceKitConfigurationFingerprint.make(user: [], project: file("{broken"), trust: .granted)
            != SourceKitConfigurationFingerprint.make(user: [], project: file("{also broken"), trust: .granted))
    }
}
