import AppKit
import Foundation
import IDEApplication
import IDETestSupport
import Testing
@testable import SwiftIDE

@MainActor private final class ProjectHostingStore: GitHostingAccountStore {
    let account: GitHostingAccount

    init(_ account: GitHostingAccount) { self.account = account }

    func load() throws -> [GitHostingAccount] { [account] }

    func save(_ accounts: [GitHostingAccount]) throws {}
}
private actor ProjectHostingFixtures: GitHostingAPI, GitHostingCredentials {
    private(set) var networkCalls = 0

    func token(account: UUID) async throws -> String { throw GitInspectionError.failed("No real credentials in tests") }

    func save(token: String, account: UUID) async throws { Issue.record("Unexpected credential mutation") }

    func remove(account: UUID) async throws { Issue.record("Unexpected credential mutation") }

    func authenticate(_ account: GitHostingAccount, token: String) async throws -> String {
        throw GitInspectionError.failed("Not used")
    }

    func requests(in repository: GitHostedRepository) async throws -> GitHostingPage<GitHostingRequest> {
        networkCalls += 1

        return .init(items: [])
    }

    func checks(in repository: GitHostedRepository, sha: String) async throws -> GitHostingPage<GitHostingCheck> {
        networkCalls += 1

        return .init(items: [.init(name: "fixture build", state: "success")])
    }

    func branchSHA(in repository: GitHostedRepository, branch: String) async throws -> String {
        throw GitInspectionError.failed("Not used")
    }

    func create(in repository: GitHostedRepository, request: GitHostingCreate) async throws -> GitHostingRequest {
        throw GitInspectionError.failed("No publication in tests")
    }
}

extension NativeAppTests {
    @MainActor struct GitExtendedProjectTests {
        private func wait(_ predicate: () -> Bool) async throws {
            let end = ContinuousClock.now + .seconds(20)
            while !predicate(), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(5)) }
            try #require(predicate())
        }

        private func git(_ arguments: [String], _ root: URL) throws {
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", root.path] + arguments
            process.standardOutput = output
            process.standardError = output
            try process.run()
            let bytes = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw GitInspectionError.failed(String(decoding: bytes, as: UTF8.self))
            }
        }

        private func fixture() throws -> URL {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("SwiftIDE-extended-app-" + UUID().uuidString).resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try git(["init", "-b", "main"], root)
            try git(["config", "user.name", "Fixture"], root)
            try git(["config", "user.email", "fixture@example.test"], root)
            try git(["config", "commit.gpgsign", "false"], root)
            try "base\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
            try git(["add", "."], root)
            try git(["commit", "-m", "Base"], root)
            try git(["branch", "onto"], root)
            try git(["remote", "add", "origin", "git@github.com:org/repo.git"], root)

            return root
        }

        @Test func extendedSheetsBelongToTheirProjectAndHostingWaitsForExplicitRefresh() async throws {
            _ = NSApplication.shared
            let first = try fixture(), second = try fixture()
            defer {
                try? FileManager.default.removeItem(at: first)
                try? FileManager.default.removeItem(at: second)
            }
            let name = "SwiftIDE-extended-settings-" + UUID().uuidString
            let defaults = try #require(UserDefaults(suiteName: name))
            defer { defaults.removePersistentDomain(forName: name) }
            let api = ProjectHostingFixtures()
            let account = try GitHostingAccount(
                service: .github,
                webURL: #require(URL(string: "https://github.com")),
                login: "fixture"
            )
            let accounts = GitHostingAccounts(store: ProjectHostingStore(account), credentials: api, api: api)
            let app = AppDelegate(composition: AppCompositionRoot(
                recoveryStore: MemoryRecoveryStore(),
                layoutDefaults: defaults,
                recentStore: MemoryRecentProjectsStore(),
                gitHostingAccounts: accounts
            ))
            let a = app.openProject(path: first.path), b = app.openProject(path: second.path)
            a.layout.onSave = nil
            b.layout.onSave = nil
            a.files.onExclusionsChange = nil
            b.files.onExclusionsChange = nil
            defer {
                a.closeProject()
                b.closeProject()
                app.welcome?.close()
            }
            a.showWorkspace()
            b.showWorkspace()
            let gitA = try #require(a.git), gitB = try #require(b.git)
            try await wait { gitA.canMutate && gitB.canMutate }
            a.hostingGit(nil)
            let hosting = try #require(a.hostingWindow)
            #expect(hosting.window?.sheetParent === a.window && b.hostingWindow == nil)
            #expect(hosting.content.model.workspace === gitA)
            #expect(await api.networkCalls == 0)
            hosting.content.model.refresh()
            try await wait { hosting.content.model.state == .ready }
            #expect(hosting.content.model.checksSHA == gitA.snapshot?.head)
            #expect(hosting.content.model.checks.first?.name == "fixture build")
            hosting.dismiss()
            #expect(a.hostingWindow == nil && !hosting.content.model.canRead)
            a.manageGit(nil)
            b.interactiveRebaseGit(nil)
            let management = try #require(a.managementWindow), interactive = try #require(b.interactiveRebaseWindow)
            #expect(management.window?.sheetParent === a.window && interactive.window?.sheetParent === b.window)
            #expect(management.content.review.workspace === gitA && interactive.content.model.workspace === gitB)
            management.dismiss()
            #expect(a.managementWindow == nil && b.interactiveRebaseWindow === interactive)
            interactive.dismiss()
            a.repositoryOperationsGit(nil)
            let operations = try #require(a.repositoryOperationWindow)
            #expect(operations.window?.sheetParent === a.window && operations.content.model.workspace === gitA)
            operations.dismiss()
            #expect(a.repositoryOperationWindow == nil)
        }

        private func button(_ title: String, in view: NSView) -> NSButton? {
            if let button = view as? NSButton, button.title == title { return button }

            return view.subviews.lazy.compactMap { self.button(title, in: $0) }.first
        }

        @Test func historyCIOpensOnlyItsProjectSheetForTheSelectedOlderCommit() async throws {
            _ = NSApplication.shared
            let root = try fixture()
            defer { try? FileManager.default.removeItem(at: root) }
            try "next\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
            try git(["commit", "-am", "Next"], root)
            let name = "SwiftIDE-history-ci-" + UUID().uuidString
            let defaults = try #require(UserDefaults(suiteName: name))
            defer { defaults.removePersistentDomain(forName: name) }
            let api = ProjectHostingFixtures()
            let account = try GitHostingAccount(
                service: .github,
                webURL: #require(URL(string: "https://github.com")),
                login: "fixture"
            )
            let accounts = GitHostingAccounts(store: ProjectHostingStore(account), credentials: api, api: api)
            let app = AppDelegate(composition: AppCompositionRoot(
                recoveryStore: MemoryRecoveryStore(),
                layoutDefaults: defaults,
                recentStore: MemoryRecentProjectsStore(),
                gitHostingAccounts: accounts
            ))
            let project = app.openProject(path: root.path)
            project.layout.onSave = nil
            project.files.onExclusionsChange = nil
            defer {
                project.closeProject()
                app.welcome?.close()
            }
            project.showWorkspace()
            let git = try #require(project.git), log = try #require(project.gitLog)
            try await wait { git.canMutate && git.history.count == 2 }
            let older = git.history[1]
            #expect(older.oid != git.snapshot?.head)
            let inspect = try #require(log.inspectCI)
            inspect(older)
            let hosting = try #require(project.hostingWindow)
            #expect(hosting.window?.sheetParent === project.window && hosting.content.model.workspace === git)
            #expect(await api.networkCalls == 0)
            var forwarded: [String] = []
            let original = hosting.onChecks
            hosting.onChecks = { sha, checks, limited, date, source in
                forwarded.append(sha)
                original?(sha, checks, limited, date, source)
            }
            let refresh = try #require(button("Refresh PR/MR and CI", in: hosting.content.view))
            try await wait { refresh.isEnabled }
            // performClick inside a sheet stops the test process's main run loop; send the button's own action.
            #expect(refresh.sendAction(refresh.action, to: refresh.target))
            try await wait { hosting.content.model.state == .ready && !forwarded.isEmpty }
            #expect(hosting.content.model.checksSHA == older.oid && forwarded == [older.oid])
            #expect(await api.networkCalls == 2)
            hosting.dismiss()
            #expect(project.hostingWindow == nil)
        }
    }
}
