import AppKit
import IDEApplication
import IDETestSupport
import Testing
@testable import SwiftIDE
@testable import WorkspaceUI

extension NativeAppTests {
    @Suite(.serialized)
    @MainActor
    struct GitTrackingProjectTests {
        private func wait(_ predicate: () -> Bool) async throws {
            let end = ContinuousClock.now + .seconds(20)
            while !predicate(), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(5)) }
            try #require(predicate())
        }

        @Test func projectSheetCreatesTrackingWithoutChangingDirtyEditorAndClosesWithItsOwner() async throws {
            _ = NSApplication.shared
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftIDE-tracking-app-\(UUID())")
                .resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            try git(["init", "-b", "main"], root)
            try git(["config", "user.name", "Test Author"], root)
            try git(
                ["config", "user.email", "author@example.test"],
                root
            )
            try git(["config", "commit.gpgsign", "false"], root)
            let path = root.appendingPathComponent("a.txt")
            try "base\n".write(to: path, atomically: true, encoding: .utf8)
            try git(["add", "."], root)
            try git(["commit", "-m", "Base"], root)
            try git(["remote", "add", "origin", "https://example.invalid/repo.git"], root)
            try git(["update-ref", "refs/remotes/origin/feature/remote", "HEAD"], root)
            let app = AppDelegate(composition: AppCompositionRoot(
                recoveryStore: MemoryRecoveryStore(),
                recentStore: MemoryRecentProjectsStore()
            ))
            let project = app.openProject(path: root.path)
            project.layout.onSave = nil
            project.files.onExclusionsChange = nil
            defer {
                project.closeProject()
                app.welcome?.close()
            }
            project.showWorkspace()
            let model = try #require(project.git)
            try await wait { model.canMutate }
            await app.open(path: path.path, in: project)
            let document = try #require(project.activeDocument),
                editor = try #require(document.focusTarget as? NSTextView)
            editor.insertText("dirty ", replacementRange: NSRange(location: 0, length: 0))
            let text = document.session.text
            let source = try #require(model.snapshot?.branches.first { $0.isRemote })
            let menu = NSMenuItem(
                title: "Branch Tracking…",
                action: #selector(ProjectWorkspaceController.trackingGit(_:)),
                keyEquivalent: ""
            )
            #expect(project.validateMenuItem(menu))
            project.showTracking(branch: source)
            let sheet = try #require(project.trackingWindow)
            #expect(sheet.window?.sheetParent === project.window)
            sheet.content.name.stringValue = "feature/local"
            sheet.content.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
            sheet.content.reviewSelection(nil)
            try await wait { sheet.content.model.canApply }
            #expect(model.snapshot?.branches.contains { $0.name == "feature/local" } == false)
            sheet.content.applyReviewed(nil)
            try await wait { project.trackingWindow == nil && model.canMutate && model.operationState == .succeeded }
            let created = try #require(model.snapshot?.branches.first { $0.name == "feature/local" })
            #expect(created.oid == source.oid && created.upstreamRemote == "origin" && created
                .upstreamSource == "refs/heads/feature/remote")
            #expect(model.snapshot?.branch == "main" && project.activeDocument === document)
            #expect(document.session.isDirty && document.session.text == text && editor.undoManager?.canUndo == true)
            #expect(try String(contentsOf: path, encoding: .utf8) == "base\n")
            project.showTracking(branch: created)
            let closed = try #require(project.trackingWindow)
            project.closeProject()
            #expect(project.trackingWindow == nil && closed.window?.sheetParent == nil)
        }

        private func git(_ arguments: [String], _ root: URL) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process
                .arguments = ["-C", root.path] + arguments
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process
                .standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            try #require(process.terminationStatus == 0)
        }
    }
}
