import AppKit
import IDEApplication
import IDETestSupport
import Testing
import WorkspaceUI
@testable import SwiftIDE

extension NativeAppTests {
    @Suite(.serialized) @MainActor
    struct GitLocalProjectTests {
        private func wait(_ predicate: () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(15)
            while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
            try #require(predicate())
        }

        private func completed(_ model: GitWorkspace) async throws {
            try await wait { !model.operationState.isBusy && model.state == .ready }
        }

        @Test func checkoutReconcilesOtherWindowsAndLocalActionsPreserveBuffersAndUndo() async throws {
            _ = NSApplication.shared
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftIDE-git-local-\(UUID())")
                .resolvingSymlinksInPath()
            let sub = root.appendingPathComponent("Sub")
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let aPath = root.appendingPathComponent("a.txt"), bPath = sub.appendingPathComponent("b.txt")
            try git(["init", "-b", "main"], root)
            try git(["config", "user.name", "Test Author"], root)
            try git(["config", "user.email", "author@example.test"], root)
            try git(["config", "commit.gpgsign", "false"], root)
            try "base a\n".write(to: aPath, atomically: true, encoding: .utf8)
            try "base b\n".write(to: bPath, atomically: true, encoding: .utf8)
            try git(["add", "."], root)
            try git(["commit", "-m", "Base"], root)
            try git(["switch", "-c", "other"], root)
            try "other a\n".write(to: aPath, atomically: true, encoding: .utf8)
            try "other b\n".write(to: bPath, atomically: true, encoding: .utf8)
            try git(["commit", "-am", "Other"], root)
            try git(["switch", "main"], root)
            var saveAll = false, asked: [String] = []
            let app = AppDelegate(
                composition: AppCompositionRoot(
                    recoveryStore: MemoryRecoveryStore(),
                    recentStore: MemoryRecentProjectsStore()
                ),
                gitCheckoutPrompt: { document in
                    asked.append(document.path)

                    return saveAll || document.path == aPath.path ? .save : .cancel
                }
            )
            let project = app.openProject(path: root.path), second = app.openProject(path: sub.path)
            project.layout.onSave = nil
            second.layout.onSave = nil
            project.files.onExclusionsChange = nil
            second.files.onExclusionsChange = nil
            defer {
                project.closeProject()
                second.closeProject()
                app.welcome?.close()
            }
            let model = try #require(project.git)
            try await wait { model.state == .ready && second.git?.state == .ready }
            await app.open(path: aPath.path, in: project)
            await app.open(path: bPath.path, in: second)
            let a = try #require(project.activeDocument), b = try #require(second.activeDocument)
            let aEditor = try #require(a.focusTarget as? NSTextView),
                bEditor = try #require(b.focusTarget as? NSTextView)
            aEditor.insertText("saved ", replacementRange: NSRange(location: 0, length: 0))
            bEditor.insertText("saved ", replacementRange: NSRange(location: 0, length: 0))
            let aText = a.session.text, bText = b.session.text
            let branch = try #require(model.snapshot?.branches.first { $0.name == "other" })
            model.perform(.switchBranch(branch))
            try await completed(model)
            #expect(model.operationState == .cancelled && model.snapshot?.branch == "main")
            #expect(project.shell.notifications.items.first?.kind == .information)
            #expect(asked == [aPath.path, bPath.path] && !a.session.isDirty && b.session.isDirty)
            #expect(a.session.text == aText && b.session.text == bText)
            saveAll = true
            model.perform(.switchBranch(branch))
            try await completed(model)
            if case .failed = model.operationState {} else {
                Issue.record("Git must refuse overwriting conflicting saved disk edits")
            }

            #expect(project.shell.notifications.items.first?.kind == .error)
            #expect(model.snapshot?.branch == "main" && aEditor.isEditable && bEditor.isEditable)
            #expect(a.session.text == aText && b.session.text == bText && bEditor.undoManager?.canUndo == true)
            for path in ["a.txt", "Sub/b.txt"] {
                let change = try #require(model.snapshot?.changes.first { $0.path == path })
                model.perform(.stage(change))
                try await completed(model)
                #expect(model.operationState == .succeeded)
            }
            model.perform(.commit("Saved main edits"))
            try await completed(model)
            #expect(model.operationState == .succeeded && model.snapshot?.changes.isEmpty == true)
            let notification = try #require(project.shell.notifications.items.first)
            #expect(notification.id == "git.operation" && notification.kind == .success)
            #expect(notification.title == "Commit staged changes completed")
            #expect(second.shell.notifications.items.isEmpty, "another project did not run this operation")
            project.shell.notifications.dismiss(notification.id)
            model.refresh()
            try await wait { model.state == .ready }
            #expect(
                project.shell.notifications.items.isEmpty,
                "status refresh does not replay an old operation notification"
            )
            let prepare = try #require(model.prepareCheckout)
            var sawLocks = false
            model.prepareCheckout = { repository in
                let prepared = await prepare(repository)
                if prepared {
                    sawLocks = !aEditor.isEditable && !bEditor.isEditable && aEditor.undoManager?
                        .canUndo == false && bEditor.undoManager?.canUndo == false
                    aEditor.undoManager?.undo()
                    #expect(a.session.text == aText, "checkout lock must preserve Undo history without executing it")
                    #expect(await a.save() == false)
                }

                return prepared
            }
            model.perform(.switchBranch(branch))
            try await completed(model)
            #expect(model.operationState == .succeeded && model.snapshot?.branch == "other" && sawLocks)
            try await wait { a.session.text == "other a\n" && b.session.text == "other b\n" }
            #expect(aEditor.isEditable && bEditor.isEditable && !a.session.isDirty && !b.session.isDirty)
            #expect(project.documents.first === a && second.documents.first === b)
            aEditor.undoManager?.undo()
            #expect(a.session.text == aText && a.session.isDirty)
            #expect(try String(contentsOf: aPath, encoding: .utf8) == "other a\n")
            try await wait { model.canMutate }
            model.perform(.createBranch("created/local"))
            try await completed(model)
            #expect(model.operationState == .succeeded && model.snapshot?.branch == "other")
            #expect(model.snapshot?.branches.contains { $0.name == "created/local" } == true)
            project.commitGit(nil)
            project.window?.setContentSize(NSSize(width: 900, height: 560))
            for (name, theme) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                project.window?.appearance = NSAppearance(named: theme)
                let view = try #require(project.window?.contentView)
                view.layoutSubtreeIfNeeded()
                let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try #require(bitmap.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: "/private/tmp/swiftide-git-local-project-\(name).png"))
            }

        }

        private func git(_ arguments: [String], _ root: URL) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", root.path] + arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            try #require(process.terminationStatus == 0)
        }
    }
}
