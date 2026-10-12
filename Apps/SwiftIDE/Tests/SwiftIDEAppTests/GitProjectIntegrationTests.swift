import AppKit
import IDEApplication
import IDETestSupport
import Testing
import WorkspaceUI
@testable import SwiftIDE

extension NativeAppTests {
    @Suite(.serialized) @MainActor
    struct GitProjectIntegrationTests {
        private func wait(_ predicate: () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(15)
            while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            try #require(predicate())
        }
        @Test func actualRepositoryDecoratesFilesAndDiffTabRetainsOriginalDirtyEditor() async throws {
            _ = NSApplication.shared
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftIDE-git-app-\(UUID())")
                .resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            try git(["init", "-b", "main"], root: root)
            try git(["config", "user.name", "Test Author"], root: root)
            try git(["config", "user.email", "author@example.test"], root: root)
            try git(["config", "commit.gpgsign", "false"], root: root)
            let path = root.appendingPathComponent("a.txt")
            try "before\n".write(to: path, atomically: true, encoding: .utf8)
            try git(["add", "."], root: root); try git(["commit", "-m", "Initial"], root: root)
            try "on disk\n".write(to: path, atomically: true, encoding: .utf8)
            let app = AppDelegate(composition: AppCompositionRoot(
                recoveryStore: MemoryRecoveryStore(),
                recentStore: MemoryRecentProjectsStore()
            ))
            let project = app.openProject(path: root.path)
            project.layout.onSave = nil; project.files.onExclusionsChange = nil
            defer { project.closeProject(); app.welcome?.close() }
            let model = try #require(project.git)
            try await wait { model.state == .ready }
            #expect(project.files.decoration(for: path.path).tone == .blue)
            #expect(project.layout.available.contains(.sourceControl) && project.layout.available.contains(.gitLog))
            await app.open(path: path.path, in: project)
            let document = try #require(project.activeDocument)
            let editor = try #require(document.focusTarget as? NSTextView)
            editor.insertText("unsaved ", replacementRange: NSRange(location: 0, length: 0))
            let dirtyText = document.session.text
            let changed = try #require(model.snapshot?.changes.first { $0.path == "a.txt" })
            model.inspect(.worktree(changed))
            try await wait { model.diffState == .ready }
            #expect(project.area.active is GitDiffViewController)
            #expect(project.area.tabs.items.count == 2 && project.documents.count == 1)
            #expect(project.activeDocument == nil)
            #expect(model.diffText.contains("+on disk") && !model.diffText.contains("+unsaved"))
            #expect(document.session.text == dirtyText && document.session.isDirty)
            project.closeDocument(nil)
            #expect(project.area.active === document && project.area.tabs.items.count == 1)
            editor.undoManager?.undo()
            #expect(document.session.text == "on disk\n")
            // Native events refresh nested disk paths without focus or selection changes.
            let selected = project.tabs.selected
            project.window?.makeFirstResponder(editor)
            try "new\n".write(to: root.appendingPathComponent("external.txt"), atomically: true, encoding: .utf8)
            try await wait { model.snapshot?.changes.contains { $0.path == "external.txt" } == true }
            #expect(project.tabs.selected == selected && project.window?.firstResponder === editor)
            #expect(project.files.decoration(for: root.appendingPathComponent("external.txt").path).tone == .red)
            for (name, theme) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                if !project.layout.layout.contains(.sourceControl) { project.layout.select(.sourceControl) }
                if !project.layout.layout.contains(.gitLog) { project.layout.select(.gitLog) }
                model.inspect(.worktree(changed)); try await wait { model.diffState == .ready }
                project.window?.appearance = NSAppearance(named: theme)
                let view = try #require(project.window?.contentView)
                view.layoutSubtreeIfNeeded()
                let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try #require(bitmap.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: "/private/tmp/swiftide-git-project-\(name).png"))
            }
        }

        private func git(_ arguments: [String], root: URL) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", root.path] + arguments
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit()
            try #require(process.terminationStatus == 0)
        }
    }
}
