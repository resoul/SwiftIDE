import AppKit
import IDEApplication
import Testing
@testable import WorkspaceUI

@Suite(.serialized)
@MainActor
struct ProjectTrustPresenterTests {
    private func window() -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: -2000, y: -2000, width: 400, height: 240), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)

        return window
    }

    private func waitFor(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }

        return condition()
    }

    @Test func theExplanationAndActualDefaultButtonPreserveTheAgreedMeaning() {
        let content = ProjectTrustDialog.content(projectName: "App")
        #expect(content.title == "Allow the project configuration?")
        #expect(content.detail.contains("“App”"))
        #expect(content.detail.contains("may launch external processes and change the parameters of their execution"))
        #expect(content.detail.contains("does not stop the processing of the manifest and the SwiftPM preparation"))
        #expect(content.buttons == ["Don't allow", "Allow configuration"])
        let alert = ProjectTrustDialog.makeAlert(projectName: "App")
        #expect(alert.messageText == content.title && alert.informativeText == content.detail)
        #expect(alert.buttons.map(\.title) == content.buttons)
        #expect(alert.buttons.map(\.keyEquivalent) == ["\r", ""], "Return refuses, never grants")
        #expect(alert.alertStyle == .warning)
    }

    @Test func onlyTheTwoDecisionButtonsProduceADecision() {
        #expect(ProjectTrustDialog.decision(forButton: .alertFirstButtonReturn) == .refused)
        #expect(ProjectTrustDialog.decision(forButton: .alertSecondButtonReturn) == .granted)
        #expect(ProjectTrustDialog.decision(forButton: .stop) == nil)
        #expect(ProjectTrustDialog.decision(forButton: .abort) == nil)
        #expect(ProjectTrustDialog.decision(forButton: .cancel) == nil)
    }

    @Test(arguments: [NSApplication.ModalResponse.alertFirstButtonReturn, .alertSecondButtonReturn])
    func theSheetIsAttachedOnlyToTheExplicitParentAndReturnsItsAnswer(response: NSApplication.ModalResponse) async throws {
        let parent = window(), other = window()
        other.makeKey()
        let presenter = ProjectTrustPresenter()
        let task = Task { await presenter.ask(projectName: "Project A", parent: parent) }
        defer { presenter.cancel(for: parent); parent.close(); other.close() }
        try #require(await waitFor { parent.attachedSheet != nil })
        #expect(other.attachedSheet == nil && NSApp.modalWindow == nil, "no application-wide modal loop")
        let sheet = try #require(parent.attachedSheet)
        #expect(sheet.sheetParent === parent)
        let field = NSTextField(string: "editable")
        other.contentView = field
        #expect(other.makeFirstResponder(field), "the unrelated window remains usable")
        field.stringValue = "still editable"
        parent.endSheet(sheet, returnCode: response)
        let watchdog = Task { try? await Task.sleep(for: .seconds(10)); presenter.cancel(for: parent) }
        defer { watchdog.cancel() }
        #expect(await task.value == ProjectTrustDialog.decision(forButton: response))
        #expect(parent.attachedSheet == nil)
    }

    @Test func closingTheOwnerCancelsAndTheNextWindowCanAskAgain() async throws {
        let parent = window()
        let presenter = ProjectTrustPresenter()
        let task = Task { await presenter.ask(projectName: "A", parent: parent) }
        defer { presenter.cancel(for: parent); parent.close() }
        try #require(await waitFor { parent.attachedSheet != nil })
        parent.close()
        let watchdog = Task { try? await Task.sleep(for: .seconds(10)); presenter.cancel(for: parent) }
        defer { watchdog.cancel() }
        #expect(await task.value == nil)
        #expect(parent.attachedSheet == nil)

        let reopened = window()
        let next = Task { await presenter.ask(projectName: "A", parent: reopened) }
        defer { presenter.cancel(for: reopened); reopened.close() }
        try #require(await waitFor { reopened.attachedSheet != nil })
        presenter.cancel(for: reopened)
        #expect(await next.value == nil)
    }

    @Test func cancellingTheRequestDismissesTheSheetWithoutAUserDecision() async throws {
        let parent = window()
        let presenter = ProjectTrustPresenter()
        let task = Task { await presenter.ask(projectName: "A", parent: parent) }
        defer { presenter.cancel(for: parent); parent.close() }
        try #require(await waitFor { parent.attachedSheet != nil })
        task.cancel()
        try #require(await waitFor { parent.attachedSheet == nil })
        #expect(await task.value == nil)
        presenter.cancel(for: parent) // A late second cancellation cannot resume twice.
    }

    @Test func aSecondQuestionCannotReplaceAnExistingSheet() async throws {
        let parent = window()
        let presenter = ProjectTrustPresenter()
        let task = Task { await presenter.ask(projectName: "A", parent: parent) }
        defer { presenter.cancel(for: parent); parent.close() }
        try #require(await waitFor { parent.attachedSheet != nil })
        let original = parent.attachedSheet
        #expect(await presenter.ask(projectName: "B", parent: parent) == nil)
        #expect(parent.attachedSheet === original)
        presenter.cancel(for: parent)
        #expect(await task.value == nil)
    }
}
