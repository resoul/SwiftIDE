import AppKit
import IDEApplication
import IDETestSupport
import Testing
import WorkspaceUI
@testable import SwiftIDE

extension NativeAppTests {
    @Suite(.serialized)
    @MainActor
    struct WorkspaceModuleFactoryTests {
        @Test func factoryRetainsInjectedModelsAndAssemblesContainmentWithoutStartingOperations() async throws {
            _ = NSApplication.shared
            let root = "/workspace-module-fixture-\(UUID())"
            let files = ProjectFiles(root: root, reader: ModuleDirectoryReader())
            let layout = WorkspaceLayoutState(available: [.files, .sourceControl, .gitLog, .assistant])
            let service = ModuleGitService()
            let git = GitWorkspace(root: root, service: service)
            let agent = AppCompositionRoot.makeDemoAgentSession()
            let module = WorkspaceModuleFactory().make(files: files, layout: layout, git: git, agent: agent)
            defer {
                module.stop()
                module.window.close()
            }
            #expect(module.files === files && module.layout === layout && module.git === git && module.agent === agent)
            #expect(module.window.contentViewController === module.browser)
            #expect(module.browser.workspace.state === layout)
            #expect(module.window.toolbar != nil && module.window.tabbingMode == .disallowed)
            #expect(module.area.parent === module.browser && module.chat.parent === module.browser)
            #expect(module.gitChanges?.parent === module.browser && module.gitLog?.parent === module.browser)
            #expect(module.gitBranches?.parent === module.browser && module.gitChanges?.model === git)
            #expect(module.area.view.isDescendant(of: module.browser.view))
            #expect(module.tabs.order.isEmpty && agent.state == .ready && agent.messages.isEmpty)
            await Task.yield()
            #expect(await service.calls == 0 && git.state == .idle, "assembly does not start Git work")
            #expect(module.quickOpen.root == root && module.quickOpen.state == .idle, "assembly lists no files")
        }

        @Test func compositionSharesAppServicesButCreatesIndependentProjectScopes() throws {
            _ = NSApplication.shared
            let suite = "SwiftIDE.module.tests.\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let composition = AppCompositionRoot(
                recoveryStore: MemoryRecoveryStore(),
                layoutDefaults: defaults,
                recentStore: MemoryRecentProjectsStore()
            )
            let base = "/workspace-scopes-\(UUID())"
            let a = composition.makeWorkspace(root: base + "/first")
            let b = composition.makeWorkspace(root: base + "/second")
            a.layout.onSave = nil
            b.layout.onSave = nil
            defer {
                a.stop()
                b.stop()
                a.window.close()
                b.window.close()
            }
            #expect(a !== b && a.window !== b.window && a.browser !== b.browser && a.area !== b.area)
            #expect(a.files !== b.files && a.layout !== b.layout && a.agent !== b.agent && a.git !== b.git)
            #expect(a.tabs !== b.tabs && a.chat !== b.chat)
            #expect(a.hostingAccounts === composition.gitHostingAccounts && b.hostingAccounts === a.hostingAccounts)
            a.agent.setDraft("first project")
            b.agent.setDraft("second project")
            a.browser.workspace.select(.assistant)
            a.browser.workspace.toggleFocusEditor(nil)
            a.browser.workspace.toggleFocusEditor(nil)
            #expect(a.agent.draft == "first project" && b.agent.draft == "second project")
            a.stop()
            a.stop()
            #expect(a.agent.state == .stopped && b.agent.state == .ready && b.agent.canSend)
            #expect(b.browser.workspace.state === b.layout && b.agent.draft == "second project")
        }

        @Test func controllerUsesAssembledCustomPanelAndClosingStopsItsModule() throws {
            _ = NSApplication.shared
            let files = ProjectFiles(root: "/workspace-custom-\(UUID())", reader: ModuleDirectoryReader())
            let layout = WorkspaceLayoutState(available: [.files, .assistant])
            let custom = NSTextField(string: "caller-supplied panel")
            let agent = AppCompositionRoot.makeDemoAgentSession()
            let module = WorkspaceModuleFactory().make(
                files: files,
                layout: layout,
                panels: [.assistant: .init(view: custom, focusTarget: custom)],
                agent: agent
            )
            let project = ProjectWorkspaceController(module: module)
            defer { project.closeProject() }
            #expect(project.window === module.window && project.area === module.area && project.tabs === module.tabs)
            #expect(project.chat === module.chat && project.agent === module.agent)
            #expect(module.gitChanges == nil && module.gitLog == nil && module.gitBranches == nil && module
                .gitDiff == nil)
            project.showAssistant(nil)
            #expect(layout.layout.right == .assistant && custom.isDescendant(of: module.browser.view))
            let area = project.area
            project.toggleFocusEditor(nil)
            project.toggleFocusEditor(nil)
            #expect(project.area === area && custom.stringValue == "caller-supplied panel")
            project.closeProject()
            #expect(agent.state == .stopped)
        }
    }
}

private struct ModuleDirectoryReader: ProjectDirectoryReading {
    func children(of path: String) async throws -> [ProjectFile] { [] }
}

private actor ModuleGitService: GitInspecting {
    private(set) var calls = 0

    func snapshot(at projectRoot: String) async throws -> GitSnapshot {
        calls += 1
        throw GitInspectionError.unavailable("Fixture has no repository")
    }

    func history(
        in repository: GitRepository,
        revision: String,
        offset: Int,
        count: Int
    ) async throws -> GitHistoryPage {
        .init(commits: [], hasMore: false)
    }

    func files(in repository: GitRepository, commit: GitCommit) async throws -> [GitCommitFile] { [] }

    func diff(in repository: GitRepository, comparison: GitComparison) async throws -> String { "" }
}
