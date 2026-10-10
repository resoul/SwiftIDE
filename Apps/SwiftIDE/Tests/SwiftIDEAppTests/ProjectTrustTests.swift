import AppKit
import IDEApplication
import Testing
@testable import SwiftIDE

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

    @Test func theQuestionSaysWhatDecliningDoesAndDoesNotDoAndRefusalIsTheDefault() {
        let content = ProjectTrustDialog.content(projectName: "App")
        #expect(content.title == "Allow the project configuration?")
        #expect(content.detail.contains("App"))
        #expect(content.detail.contains("may launch external processes and change the parameters of their execution"))
        #expect(content.detail.contains("does not stop the processing of the manifest and the SwiftPM preparation"))
        #expect(content.buttons == ["Don't allow", "Allow configuration"], "the first button is the default one")
    }

    @Test func theAnswerOfTheDialogIsRefusalUnlessTheSecondButtonWasPressed() {
        #expect(ProjectTrustDialog.decision(forButton: .alertFirstButtonReturn) == .refused)
        #expect(ProjectTrustDialog.decision(forButton: .alertSecondButtonReturn) == .granted)
        #expect(ProjectTrustDialog.decision(forButton: .stop) == .refused, "anything else is a refusal")
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
