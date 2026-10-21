import AppKit
import IDEApplication
import IDETestSupport
import Testing
import WorkspaceUI
@testable import SwiftIDE

extension NativeAppTests {
    @Suite(.serialized) @MainActor
    struct FilesGitMenuTests {
        private func wait(_ predicate: () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(15)
            while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
            try #require(predicate())
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

        private func item(_ title: String, in entries: [FileMenuEntry]) -> (isEnabled: Bool, perform: () -> Void)? {
            for case .action(let name, _, let enabled, let perform) in entries where name == title {
                return (enabled, perform)
            }

            return nil
        }

        @Test func theFileMenuStagesUnstagesAndShowsTheDiffAndSharesTheGitMenusAvailability() async throws {
            _ = NSApplication.shared
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftIDE-files-git-\(UUID())")
                .resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let tracked = root.appendingPathComponent("a.txt"), fresh = root.appendingPathComponent("new.txt")
            try git(["init", "-b", "main"], root)
            try git(["config", "user.name", "Test Author"], root)
            try git(["config", "user.email", "author@example.test"], root)
            try git(["config", "commit.gpgsign", "false"], root)
            try "base\n".write(to: tracked, atomically: true, encoding: .utf8)
            try git(["add", "."], root)
            try git(["commit", "-m", "Base"], root)
            try "changed\n".write(to: tracked, atomically: true, encoding: .utf8)
            try "fresh\n".write(to: fresh, atomically: true, encoding: .utf8)
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
            let model = try #require(project.git)
            try await wait { model.state == .ready && model.snapshot?.changes.count == 2 }

            var entries = project.gitMenuEntries(for: tracked.path)
            #expect(item("Add", in: entries)?.isEnabled == true && item("Unstage", in: entries)?.isEnabled == false)
            #expect(item("Show Diff", in: entries)?.isEnabled == true)
            #expect(item("Push…", in: entries) != nil && item("Clone Repository…", in: entries) != nil)
            #expect(
                item("Add", in: project.gitMenuEntries(for: root.path + "/missing.txt")) == nil,
                "no file, no file items"
            )
            #expect(item("Add", in: project.gitMenuEntries(for: root.path)) == nil, "a folder has no file items")

            item("Add", in: entries)?.perform()
            try await wait { !model.operationState.isBusy && model.snapshot?.changes.first { $0.path == "a.txt" }?
                .decoration.index.isEmpty == false
            }
            entries = project.gitMenuEntries(for: tracked.path)
            #expect(item("Add", in: entries)?.isEnabled == false && item("Unstage", in: entries)?.isEnabled == true)
            item("Unstage", in: entries)?.perform()
            try await wait { !model.operationState.isBusy && model.snapshot?.changes.first { $0.path == "a.txt" }?
                .decoration.index.isEmpty == true
            }

            item("Show Diff", in: project.gitMenuEntries(for: fresh.path))?.perform()
            try await wait { model.comparison?.path == "new.txt" }
            #expect(model.comparison?.title.hasPrefix("Untracked") == true)
        }

        @Test func aProjectWithoutGitOffersNoGitMenu() throws {
            _ = NSApplication.shared
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftIDE-no-git-\(UUID())")
                .resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let files = ProjectFiles(root: root.path, reader: NoGitReader())
            let module = WorkspaceModuleFactory().make(files: files, agent: AppCompositionRoot.makeDemoAgentSession())
            defer {
                module.stop()
                module.window.close()
            }
            #expect(module.browser.files.gitEntries == nil)
        }
    }
}

private struct NoGitReader: ProjectDirectoryReading {
    func children(of path: String) async throws -> [ProjectFile] { [] }
}
