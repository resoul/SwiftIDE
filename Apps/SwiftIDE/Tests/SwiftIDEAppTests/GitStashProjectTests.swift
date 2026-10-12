import AppKit
import GitInfrastructure
import IDEApplication
import IDETestSupport
import Testing
@testable import SwiftIDE
@testable import WorkspaceUI

extension NativeAppTests {
    @Suite(.serialized)
    @MainActor
    struct GitStashProjectTests {
        private func wait(_ predicate: () -> Bool) async throws {
            let end = ContinuousClock.now + .seconds(20)
            while !predicate(), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(5)) }
            try #require(predicate())
        }

        @Test func stashReconcilesDirtyEditorsKeepsUndoAndPreviewsInCentralContent() async throws {
            _ = NSApplication.shared
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftIDE-stash-app-\(UUID())")
                .resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            try git(["init", "-b", "main"], root)
            try git(["config", "user.name", "Test"], root)
            try git(["config", "user.email", "author@example.test"], root)
            try git(["config", "commit.gpgsign", "false"], root)
            let path = root.appendingPathComponent("a.txt")
            let sub = root.appendingPathComponent("Sub")
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            let secondPath = sub.appendingPathComponent("b.txt")
            try "base b\n".write(to: secondPath, atomically: true, encoding: .utf8)
            try "base\n".write(to: path, atomically: true, encoding: .utf8)
            try git(["add", "."], root)
            try git(["commit", "-m", "Base"], root)
            var allowSave = false, prompts = 0
            let app = AppDelegate(
                composition: AppCompositionRoot(
                    recoveryStore: MemoryRecoveryStore(),
                    recentStore: MemoryRecentProjectsStore()
                ),
                gitCheckoutPrompt: { _ in
                    prompts += 1

                    return allowSave ? .save : .cancel
                }
            )
            let project = app.openProject(path: root.path)
            let second = app.openProject(path: sub.path)
            second.layout.onSave = nil
            second.files.onExclusionsChange = nil
            project.layout.onSave = nil
            project.files.onExclusionsChange = nil
            defer {
                second.closeProject()
                project.closeProject()
                app.welcome?.close()
            }
            project.showWorkspace()
            let model = try #require(project.git)
            try await wait { model.canMutate }
            await app.open(path: path.path, in: project)
            let document = try #require(project.activeDocument)
            let editor = try #require(document.focusTarget as? NSTextView)
            editor.insertText("edited ", replacementRange: NSRange(location: 0, length: 0))
            let saved = document.session.text
            await app.open(path: secondPath.path, in: second)
            let secondDocument = try #require(second.activeDocument)
            let secondEditor = try #require(secondDocument.focusTarget as? NSTextView)
            secondEditor.insertText("edited ", replacementRange: NSRange(location: 0, length: 0))
            let secondSaved = secondDocument.session.text
            let menu = NSMenuItem(
                title: "Stashes…",
                action: #selector(ProjectWorkspaceController.stashesGit(_:)),
                keyEquivalent: ""
            )
            try await wait { model.canMutate && project.window?.attachedSheet == nil }
            #expect(project.validateMenuItem(menu))
            project.showStashes()
            let cancelled = try #require(project.stashWindow)
            #expect(cancelled.window?.sheetParent === project.window)
            try await wait { cancelled.content.model.canReview }
            cancelled.content.reviewSelection(nil)
            cancelled.content.applyReviewed(nil)
            try await wait { project.stashWindow == nil && model.canMutate && model.operationState == .cancelled }
            #expect(prompts == 1 && document.session.text == saved && document.session.isDirty)
            #expect(secondDocument.session.text == secondSaved && secondDocument.session.isDirty)
            #expect(try await GitCLI().stashes(in: #require(model.snapshot?.repository)).entries.isEmpty)
            allowSave = true
            try await wait { model.canMutate && project.window?.attachedSheet == nil }
            project.showStashes()
            let create = try #require(project.stashWindow)
            try await wait { create.content.model.canReview }
            create.content.message.stringValue = "Editor work"
            create.content.reviewSelection(nil)
            create.content.applyReviewed(nil)
            try await wait { project.stashWindow == nil && model.canMutate && model.operationState == .succeeded }
            try await wait { document.session.text == "base\n" && !document.session.isDirty }
            try await wait { secondDocument.session.text == "base b\n" && !secondDocument.session.isDirty }
            #expect(prompts == 3 && editor.undoManager?.canUndo == true && !document.isClosed)
            #expect(secondEditor.undoManager?.canUndo == true)
            try await wait { model.canMutate && project.window?.attachedSheet == nil }
            project.showStashes()
            let preview = try #require(project.stashWindow)
            try await wait { preview.content.model.canReview }
            preview.content.list.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            preview.content.inspectSelection(nil)
            try await wait { project.stashWindow == nil && model.diffState == .ready }
            #expect(model.diffText.contains("edited base") && project.activeDocument == nil)
            #expect(project.tabs.order.contains(document.session.id))
            project.select(document.session.id)
            try await wait { model.canMutate && project.window?.attachedSheet == nil }
            project.showStashes()
            let pop = try #require(project.stashWindow)
            try await wait { pop.content.model.canReview }
            pop.content.list.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            pop.content.mode.selectItem(at: 2)
            pop.content.selectionChanged(nil)
            pop.content.reviewSelection(nil)
            pop.content.applyReviewed(nil)
            try await wait { project.stashWindow == nil && model.canMutate && model.operationState == .succeeded }
            try await wait { document.session.text == saved && !document.session.isDirty }
            try await wait { secondDocument.session.text == secondSaved && !secondDocument.session.isDirty }
            #expect(editor.undoManager?.canUndo == true && project.activeDocument === document)
            #expect(secondEditor.undoManager?.canUndo == true && second.activeDocument === secondDocument)
            #expect(try await GitCLI().stashes(in: #require(model.snapshot?.repository)).entries.isEmpty)
            try await wait { model.canMutate && project.window?.attachedSheet == nil }
            project.showStashes()
            let closed = try #require(project.stashWindow)
            project.closeProject()
            #expect(project.stashWindow == nil && closed.window?.sheetParent == nil && !closed.content.model.canReview)
        }

        private func git(_ arguments: [String], _ root: URL) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", root.path] + arguments
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            try #require(process.terminationStatus == 0)
        }
    }
}
