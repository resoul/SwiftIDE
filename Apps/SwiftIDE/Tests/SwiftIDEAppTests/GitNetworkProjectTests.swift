import AppKit
import IDEApplication
import IDETestSupport
import Testing
@testable import SwiftIDE

extension NativeAppTests {
    @Suite(.serialized) @MainActor
    struct GitNetworkProjectTests {
        private func wait(_ predicate: () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(20)
            while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
            try #require(predicate())
        }
        @Test func welcomeCloneOpensOnlySuccessAndFetchPreservesDirtyEditorAndUndo() async throws {
            _ = NSApplication.shared
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftIDE-network-\(UUID())")
                .resolvingSymlinksInPath()
            let remote = root.appendingPathComponent("remote")
            try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            try git(["init", "-b", "main"], remote)
            try git(["config", "user.name", "Author"], remote)
            try git(["config", "user.email", "test@example.test"], remote)
            try git(["config", "commit.gpgsign", "false"], remote)
            try "base\n".write(to: remote.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
            try git(["add", "."], remote); try git(["commit", "-m", "Base"], remote)
            let recent = MemoryRecentProjectsStore()
            let suite = "SwiftIDE.network.tests.\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let app = AppDelegate(
                composition: AppCompositionRoot(
                    recoveryStore: MemoryRecoveryStore(),
                    layoutDefaults: defaults,
                    recentStore: recent
                ),
                gitCheckoutPrompt: { _ in
                Issue.record("Fetch must not ask to save or lock editors"); return .cancel
            }
            )
            await app.start(); app.cloneRepository(nil)
            let controller = try #require(app.cloneWindow), clone = controller.content.model
            defer { app.cloneWindow?.dismiss(); app.welcome?.close() }
            #expect(app.welcome?.window?.attachedSheet === controller.window)
            clone.start(.init(source: root.appendingPathComponent("missing").path, parent: root.path, name: "failed"))
            try await wait { !clone.state.isBusy }
            #expect(recent.projects.isEmpty && app.cloneWindow === controller && app.welcome?.window?.isVisible == true)
            clone.start(.init(source: remote.path, parent: root.path, name: "clone"))
            let destination = root.appendingPathComponent("clone")
            try await wait { recent.projects.first?.path == destination.path }
            #expect(app.cloneWindow == nil && app.welcome?.window?.isVisible == false)
            let project = try #require(await app.openProjectFolder(path: destination.path))
            project.layout.onSave = nil; project.files.onExclusionsChange = nil
            defer { project.closeProject() }
            let model = try #require(project.git)
            try await wait { model.canMutate }
            await app.open(path: destination.appendingPathComponent("a.txt").path, in: project)
            let document = try #require(project.activeDocument),
                editor = try #require(document.focusTarget as? NSTextView)
            editor.insertText("unsaved ", replacementRange: NSRange(location: 0, length: 0))
            let text = document.session.text, head = model.snapshot?.head
            try "remote\n".write(to: remote.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
            try git(["commit", "-am", "Remote"], remote)
            try await wait { model.canMutate }
            model.perform(.fetch("origin"))
            try await wait { model.operationState == .succeeded && model.canMutate }
            #expect(model.snapshot?.head == head && model.snapshot?.behind == 1 && model.lastFetch?.remote == "origin")
            #expect(document.session.text == text && document.session.isDirty && editor.isEditable && editor
                .undoManager?.canUndo == true)
            #expect(try String(contentsOf: destination.appendingPathComponent("a.txt"), encoding: .utf8) == "base\n")
            editor.undoManager?.undo()
            #expect(document.session.text == "base\n")
        }
        @Test func pushSheetReviewsActualDestinationAndPreservesDirtyEditorAndUndo() async throws {
            _ = NSApplication.shared
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftIDE-push-\(UUID())")
                .resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            try git(["init", "-b", "main"], root)
            try git(["config", "user.name", "Author"], root)
            try git(["config", "user.email", "test@example.test"], root)
            try git(["config", "commit.gpgsign", "false"], root)
            let file = root.appendingPathComponent("a.txt"), bare = root.appendingPathComponent("remote.git")
            try "committed\n".write(to: file, atomically: true, encoding: .utf8)
            try git(["add", "."], root); try git(["commit", "-m", "Base"], root)
            try git(["clone", "--bare", root.path, bare.path], root)
            try git(["remote", "add", "origin", bare.path], root)
            let app = AppDelegate(
                composition: AppCompositionRoot(
                    recoveryStore: MemoryRecoveryStore(),
                    recentStore: MemoryRecentProjectsStore()
                ),
                gitCheckoutPrompt: { _ in
                Issue.record("Push must not reconcile checkout"); return .cancel
            }
            )
            let project = app.openProject(path: root.path)
            project.layout.onSave = nil; project.files.onExclusionsChange = nil
            defer { project.closeProject(); app.welcome?.close() }
            let workspace = try #require(project.git)
            try await wait { workspace.canMutate }
            await app.open(path: file.path, in: project)
            let document = try #require(project.activeDocument),
                editor = try #require(document.focusTarget as? NSTextView)
            editor.insertText("unsaved ", replacementRange: NSRange(location: 0, length: 0))
            let text = document.session.text
            project.pushGit(nil)
            let sheet = try #require(project.pushWindow), model = sheet.content.model
            #expect(project.window?.attachedSheet === sheet.window)
            let branch = try #require(workspace.snapshot?.branches.first { $0.name == "main" })
            model.review(branch: branch, remote: "origin", destination: "from-app")
            try await wait { model.canPush }
            #expect(model.plan?.url == bare.path && model.plan?.branch.oid == branch.oid)
            #expect(!FileManager.default.fileExists(atPath: bare.path + "/refs/heads/from-app"))
            model.push()
            #expect(editor.isEditable && editor.undoManager?.canUndo == true)
            try await wait { workspace.operationState == .succeeded && workspace.canMutate }
            #expect(try String(contentsOfFile: bare.path + "/refs/heads/from-app", encoding: .utf8) == branch
                .oid + "\n")
            #expect(document.session.text == text && document.session.isDirty && editor.isEditable)
            #expect(try String(contentsOf: file, encoding: .utf8) == "committed\n")
            sheet.dismiss(); #expect(project.pushWindow == nil && project.window?.attachedSheet == nil)
            editor.undoManager?.undo(); #expect(document.session.text == "committed\n")
        }
        @Test func pullSheetAllowsSaveCancelAndReloadsFastForwardAsUndoableEditorChange() async throws {
            _ = NSApplication.shared
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftIDE-pull-\(UUID())")
                .resolvingSymlinksInPath()
            let remote = root.appendingPathComponent("remote"), local = root.appendingPathComponent("local")
            for url in [remote, local] {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            }
            defer { try? FileManager.default.removeItem(at: root) }
            try git(["init", "-b", "main"], remote)
            try git(["config", "user.name", "Author"], remote)
            try git(["config", "user.email", "test@example.test"], remote)
            try git(["config", "commit.gpgsign", "false"], remote)
            try "base\n".write(to: remote.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
            try git(["add", "."], remote); try git(["commit", "-m", "Base"], remote)
            try git(["init", "-b", "main"], local)
            try git(["fetch", remote.path, "main"], local); try git(["reset", "--hard", "FETCH_HEAD"], local)
            try git(["remote", "add", "origin", remote.path], local)
            try "remote\n".write(to: remote.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
            try git(["commit", "-am", "Remote"], remote)
            var prompts = 0, save = false
            var answer: CheckedContinuation<GitCheckoutDocuments.Decision, Never>?
            let app = AppDelegate(
                composition: AppCompositionRoot(
                    recoveryStore: MemoryRecoveryStore(),
                    recentStore: MemoryRecentProjectsStore()
                ),
                gitCheckoutPrompt: { _ in
                prompts += 1
                if save { return .save }

                return await withCheckedContinuation { answer = $0 }
            }
            )
            let project = app.openProject(path: local.path)
            project.layout.onSave = nil; project.files.onExclusionsChange = nil
            defer { answer?.resume(returning: .cancel); project.closeProject(); app.welcome?.close() }
            let workspace = try #require(project.git)
            try await wait { workspace.canMutate }
            let file = local.appendingPathComponent("a.txt")
            await app.open(path: file.path, in: project)
            let document = try #require(project.activeDocument),
                editor = try #require(document.focusTarget as? NSTextView)
            editor.insertText("unsaved ", replacementRange: NSRange(location: 0, length: 0))
            project.pullGit(nil)
            let sheet = try #require(project.pullWindow), model = sheet.content.model
            #expect(project.window?.attachedSheet === sheet.window)
            model.review(remote: "origin", source: "main"); try await wait { model.canPull }; model.pull()
            try await wait { answer != nil }
            #expect(prompts == 1 && project.window?.attachedSheet == nil && document.session.isDirty && editor
                .isEditable)
            // Another owner can hold a sheet while preparation finishes. Pull must resume after it ends.
            let blocker = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            blocker.isReleasedWhenClosed = false
            project.window?.beginSheet(blocker, completionHandler: { _ in })
            answer?.resume(returning: .cancel); answer = nil
            try await wait { workspace.operationState == .cancelled && workspace.canMutate }
            #expect(project.window?.attachedSheet === blocker)
            project.window?.endSheet(blocker); blocker.orderOut(nil)
            try await wait { project.window?.attachedSheet === sheet.window }
            #expect(!FileManager.default.fileExists(atPath: local.path + "/.git/refs/remotes/origin/main"))
            save = true
            model.review(remote: "origin", source: "main"); try await wait { model.canPull }; model.pull()
            try await wait { if case .failed = workspace.operationState { return workspace.canMutate }; return false }
            #expect(prompts == 2 && !document.session.isDirty && editor.isEditable)
            #expect(workspace.operationState.explanation.contains("clean index"))
            #expect(try String(contentsOf: file, encoding: .utf8) == "unsaved base\n")
            #expect(!FileManager.default.fileExists(atPath: local.path + "/.git/refs/remotes/origin/main"))
            editor.undoManager?.undo(); #expect(document.session.text == "base\n")
            #expect(await document.save())
            workspace.refresh(); try await wait { workspace.canMutate && workspace.snapshot?.changes.isEmpty == true }
            model.review(remote: "origin", source: "main"); try await wait { model.canPull }; model.pull()
            try await wait {
                workspace.operationState == .succeeded && workspace.canMutate && document.session.text == "remote\n"
            }
            #expect(prompts == 2 && editor.isEditable && editor.undoManager?.canUndo == true && !document.session
                .isDirty)
            #expect(project.window?.attachedSheet === sheet.window)
            editor.undoManager?.undo(); #expect(document.session.text == "base\n" && document.session.isDirty)
            sheet.dismiss(); #expect(project.pullWindow == nil && project.window?.attachedSheet == nil)
        }

        private func git(_ arguments: [String], _ root: URL) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", root.path] + arguments
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit()
            try #require(process.terminationStatus == 0)
        }
    }
}
