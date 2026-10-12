import AppKit
import IDEApplication
import IDETestSupport
import Testing
import WorkspaceUI
@testable import SwiftIDE

extension NativeAppTests {
    @Suite(.serialized)
    @MainActor
    struct ChatProjectTests {
        private func wait(_ predicate: () -> Bool) async throws {
            let end = ContinuousClock.now + .seconds(10)
            while !predicate(), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(5)) }
            try #require(predicate())
        }

        @Test func projectChatRetainsDraftAndUnsavedContextAcrossPanelsWithoutEditingTheDocument() async throws {
            _ = NSApplication.shared
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftIDE-chat-\(UUID())")
                .resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let path = root.appendingPathComponent("a.txt")
            try "saved text".write(to: path, atomically: true, encoding: .utf8)
            let app = AppDelegate(composition: AppCompositionRoot(
                recoveryStore: MemoryRecoveryStore(),
                recentStore: MemoryRecentProjectsStore()
            ))
            let project = app.openProject(path: root.path)
            project.layout.onSave = nil
            defer {
                project.closeProject()
                app.welcome?.close()
            }
            await app.open(path: path.path)
            let document = try #require(project.activeDocument)
            let editor = try #require(document.focusTarget as? NSTextView)
            editor.insertText("unsaved ", replacementRange: NSRange(location: 0, length: 0))
            editor.setSelectedRange(NSRange(location: 0, length: 7))
            let version = document.session.version
            let capture = try #require(project.chat.captureSelection)
            let context = try capture()
            #expect(context.text == "unsaved" && context.version == version)
            #expect(project.agent.attach(context))
            project.showAssistant(nil)
            #expect(project.layout.layout.right == .assistant && project.agent.info.isDemo)
            let input = try #require(project.chat.focusTarget as? NSTextView)
            input.insertText("Explain", replacementRange: NSRange(location: 0, length: 0))
            #expect(project.agent.draft == "Explain")
            #expect(input.undoManager !== editor.undoManager)
            input.undoManager?.undo()
            #expect(document.session.version == version && editor.string == "unsaved saved text")
            input.undoManager?.redo()
            #expect(project.agent.draft == "Explain")
            project.toggleFocusEditor(nil)
            #expect(project.layout.isFocused && project.layout.layout.right == nil)
            project.toggleFocusEditor(nil)
            #expect(project.layout.layout.right == .assistant && input.string == "Explain")
            #expect(project.agent.contexts == [context])
            #expect(project.agent.send())
            project.toggleFocusEditor(nil)
            try await wait { project.agent.state == .ready }
            #expect(project.agent.messages.count == 2 && project.agent.messages.last?.status == .complete)
            #expect(project.agent.messages.first?.contexts == [context])
            #expect(document.session.version == version && editor.string == "unsaved saved text")
            #expect(try String(contentsOf: path, encoding: .utf8) == "saved text")
            project.toggleFocusEditor(nil)
            #expect(project.layout.layout.right == .assistant && project.agent.messages.count == 2)
            project.agent.setDraft("next")
            #expect(project.agent.send())
            project.closeProject()
            #expect(project.agent.state == .stopped && !project.agent.canSend)
        }

        @Test func projectsHaveIndependentDemoSessionsAndOpeningThePanelDoesNotSend() throws {
            _ = NSApplication.shared
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftIDE-chats-\(UUID())")
            let first = root.appendingPathComponent("first"), second = root.appendingPathComponent("second")
            try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let app = AppDelegate(composition: AppCompositionRoot(
                recoveryStore: MemoryRecoveryStore(),
                recentStore: MemoryRecentProjectsStore()
            ))
            let a = app.openProject(path: first.path), b = app.openProject(path: second.path)
            a.layout.onSave = nil
            b.layout.onSave = nil
            defer {
                a.closeProject()
                b.closeProject()
                app.welcome?.close()
            }
            a.showAssistant(nil)
            b.showAssistant(nil)
            #expect(a.agent !== b.agent && a.agent.messages.isEmpty && b.agent.messages.isEmpty)
            a.agent.setDraft("only first")
            #expect(b.agent.draft.isEmpty)
            a.closeProject()
            #expect(a.agent.state == .stopped && b.agent.state == .ready)
            b.agent.setDraft("still available")
            #expect(b.agent.canSend)
        }
    }
}
