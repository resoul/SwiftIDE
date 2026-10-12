import AppKit
import IDEApplication
import IDETestSupport
import Testing
@testable import SwiftIDE

extension NativeAppTests {
    @Suite(.serialized)
    @MainActor
    struct WelcomeTests {
        @Test func startupShowsWelcomeWithoutCreatingAnEditorAndDockReopenReusesIt() async throws {
            _ = NSApplication.shared
            let app = AppDelegate(composition: AppCompositionRoot(
                recoveryStore: MemoryRecoveryStore(),
                recentStore: MemoryRecentProjectsStore()
            ))
            await app.start()
            let welcome = try #require(app.welcome)
            defer { welcome.close() }
            #expect(welcome.window?.isVisible == true)
            #expect(app.projectSwitcherMenu().items.map(\.title) == ["Open Folder…", "Welcome"])
            #expect(NSApp.windows.filter(\.isVisible).allSatisfy {
                !($0.windowController is WorkspaceWindowController)
            })
            welcome.close()
            #expect(welcome.window?.isVisible == false)
            #expect(!app.applicationShouldTerminateAfterLastWindowClosed(NSApp))
            #expect(app.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false))
            #expect(app.welcome === welcome && welcome.window?.isVisible == true)
        }

        @Test func validFolderEntriesShareCanonicalIdentityAndClosingTheLastProjectReturnsWelcome() async throws {
            _ = NSApplication.shared
            let root = try temporaryFolder()
            defer { try? FileManager.default.removeItem(at: root) }
            let folder = root.appendingPathComponent("Project")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let alias = root.appendingPathComponent("Alias")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: folder)
            let suite = "SwiftIDE.welcome.layout.tests.\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let recent = MemoryRecentProjectsStore()
            let composition = AppCompositionRoot(
                recoveryStore: MemoryRecoveryStore(),
                layoutDefaults: defaults,
                recentStore: recent
            )
            let app = AppDelegate(composition: composition)
            await app.start()
            let project = try #require(await app.openProjectFolder(path: folder.path))
            defer {
                project.closeProject()
                app.welcome?.close()
            }
            #expect(project.window?.isVisible == true && app.welcome?.window?.isVisible == false)
            #expect(await app.openProjectFolder(path: alias.path) === project)
            #expect(recent.projects.map(\.path) == [folder.path])
            #expect(composition.recentProjects.openRoots == [folder.path])
            #expect(app.projectSwitcherMenu().items.filter { $0.representedObject as? String == folder.path }
                .count == 1)
            app.showWelcome(nil)
            #expect(await app.openProjectFolder(path: folder.path) === project)
            #expect(app.welcome?.window?.isVisible == false)
            await app.closeProject(project)
            #expect(composition.recentProjects.openRoots.isEmpty)
            #expect(app.welcome?.window?.isVisible == true)
            #expect(recent.projects.map(\.path) == [folder.path], "closing a project does not remove its history")
            #expect(app.projectSwitcherMenu().items.contains { $0.title == "Recent Projects" })
        }

        @Test func missingFolderPreservesHistoryAndLocateChangesOnlyItsRecentEntry() async throws {
            _ = NSApplication.shared
            let root = try temporaryFolder()
            defer { try? FileManager.default.removeItem(at: root) }
            let missing = root.appendingPathComponent("Moved")
            let destination = root.appendingPathComponent("Located")
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let recent = MemoryRecentProjectsStore(projects: [.init(
                path: missing.path,
                lastOpened: .distantPast,
                isPinned: true
            )])
            let suite = "SwiftIDE.welcome.locate.tests.\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let composition = AppCompositionRoot(
                recoveryStore: MemoryRecoveryStore(),
                layoutDefaults: defaults,
                recentStore: recent
            )
            let app = AppDelegate(composition: composition)
            await app.start()
            defer { app.welcome?.close() }
            #expect(await app.openProjectFolder(path: missing.path) == nil)
            #expect(recent.projects.first?.path == missing.path && recent.projects.first?.isPinned == true)
            #expect(composition.recentProjects.openRoots.isEmpty)
            let welcome = try #require(app.welcome?.window)
            let sheet = try #require(welcome.attachedSheet)
            welcome.endSheet(sheet, returnCode: .alertSecondButtonReturn)
            try await waitFor { welcome.attachedSheet == nil }
            #expect(recent.projects.first?.path == missing.path)
            let project = try #require(await app.openProjectFolder(path: destination.path, replacing: missing.path))
            defer { project.closeProject() }
            #expect(recent.projects.count == 1 && recent.projects.first?.path == destination.path && recent.projects
                .first?.isPinned == true)
            #expect(!FileManager.default.fileExists(atPath: missing.path))
            #expect(FileManager.default.fileExists(atPath: destination.path))
        }

        @Test func versionedMetadataReloadsAndUnreadableArchivesAreNotOverwritten() throws {
            let suite = "SwiftIDE.welcome.persistence.tests.\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = UserDefaultsRecentProjectsStore(defaults: defaults)
            let records = [
                RecentProject(path: "/work/Pinned", lastOpened: .distantPast, isPinned: true),
                .init(path: "/work/Recent", lastOpened: .now)
            ]
            try store.save(records)
            #expect(try UserDefaultsRecentProjectsStore(defaults: defaults).load() == records)
            for bytes in [Data("not JSON".utf8), Data(#"{"version":2,"projects":[]}"#.utf8)] {
                defaults.set(bytes, forKey: "recentProjects.v1")
                let model = RecentProjects(
                    store: UserDefaultsRecentProjectsStore(defaults: defaults),
                    checker: NoFolderChecker()
                )
                #expect(model.projects.isEmpty && model.storageIssue != nil)
                model.opened(canonicalPath: "/work/Session")
                #expect(model.projects.map(\.path) == ["/work/Session"] && model.storageIssue != nil)
                #expect(defaults.data(forKey: "recentProjects.v1") == bytes)
            }
        }

        @Test func startupRetainsRecoveryAndExplicitFileOpeningHidesWelcomeWithoutAddingAProject() async throws {
            _ = NSApplication.shared
            let root = try temporaryFolder()
            defer { try? FileManager.default.removeItem(at: root) }
            let file = root.appendingPathComponent("recovered.txt")
            try "disk text".write(to: file, atomically: true, encoding: .utf8)
            let recovery = MemoryRecoveryStore()
            let record = RecoveryRecord(
                key: .file(atPath: file.path),
                path: file.path,
                title: "recovered.txt",
                text: "unsaved recovery",
                encoding: .utf8,
                baseRevision: nil,
                savedAt: .now
            )
            await recovery.seed(record)
            let recent = MemoryRecentProjectsStore()
            let composition = AppCompositionRoot(recoveryStore: recovery, recentStore: recent)
            var decisions: [RecoveryCandidate] = []
            let app = AppDelegate(composition: composition, recoveryPrompt: {
                decisions.append($0)

                return true
            })
            await app.start()
            let window = try #require(NSApp.windows.first { $0.representedURL?.path == file.path })
            let document = try #require(window.windowController as? WorkspaceWindowController)
            defer {
                window.close()
                app.welcome?.close()
            }
            #expect(decisions.count == 1 && document.session.text == record.text && document.session.isDirty)
            #expect(try String(contentsOf: file, encoding: .utf8) == "disk text")
            #expect(app.welcome?.window?.isVisible == false && recent.projects.isEmpty)
            app.showWelcome(nil)
            await app.open(path: file.path)
            #expect(app.welcome?.window?.isVisible == false)
            #expect(document.session.text == record.text, "focusing the existing file must preserve unsaved text")
            window.close()
            #expect(app.welcome?.window?.isVisible == true)
        }

        private func temporaryFolder() throws -> URL {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftIDE-welcome-\(UUID())")
                .resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

            return url
        }

        private func waitFor(_ condition: () -> Bool) async throws {
            let end = ContinuousClock.now + .seconds(5)
            while !condition(), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(5)) }
            try #require(condition())
        }
    }
}

private struct NoFolderChecker: ProjectFolderChecking {
    func check(path: String) async -> ProjectFolderAvailability { .missing }
}
