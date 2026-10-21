import AppKit
import ChatUI
import IDEApplication
import WorkspaceUI

/// Stateless assembly. The caller chooses the models' lifetimes and owns the returned project module.
@MainActor
struct WorkspaceModuleFactory {
    func make(
        files: ProjectFiles,
        layout: WorkspaceLayoutState = .init(),
        panels: [WorkspaceTool: WorkspacePanel] = [:],
        git: GitWorkspace? = nil,
        agent: AgentSession,
        hostingAccounts: GitHostingAccounts? = nil,
        fileLister: any ProjectFileLister = NoProjectFileLister()
    ) -> WorkspaceModule {
        let tabs = DocumentTabs()
        let area = EditorAreaViewController()
        let chat = ChatPanelViewController(session: agent)
        let gitChanges = git.map { GitChangesViewController(model: $0) }
        let gitLog = git.map { GitLogViewController(model: $0) }
        let gitBranches = git.map { GitBranchPickerViewController(model: $0) }
        let gitDiff = git.map { GitDiffViewController(model: $0) }
        var providers = panels
        if providers[.assistant] == nil {
            providers[.assistant] = WorkspacePanel(view: chat.view, focusTarget: chat.focusTarget)
        }

        if let gitChanges {
            providers[.sourceControl] = WorkspacePanel(view: gitChanges.view, focusTarget: gitChanges.focusTarget)
        }

        if let gitLog { providers[.gitLog] = WorkspacePanel(view: gitLog.view, focusTarget: gitLog.focusTarget) }
        let browser = ProjectFilesContainer(model: files, editor: area.view, layout: layout, panels: providers)
        browser.addChild(area)
        browser.addChild(chat)
        for controller in [gitChanges, gitLog, gitBranches] as [NSViewController?] {
            if let controller { browser.addChild(controller) }
        }
        if let gitBranches { browser.workspace.installProjectAccessory(gitBranches.view) }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = (files.root as NSString).lastPathComponent
        window.representedURL = URL(fileURLWithPath: files.root)
        window.titleVisibility = .hidden
        window.contentViewController = browser
        browser.workspace.installWindowToolbar(on: window)
        window.minSize = NSSize(width: 900, height: 560)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.center()

        return WorkspaceModule(
            window: window,
            files: files,
            layout: layout,
            tabs: tabs,
            area: area,
            git: git,
            agent: agent,
            chat: chat,
            gitChanges: gitChanges,
            gitLog: gitLog,
            gitBranches: gitBranches,
            gitDiff: gitDiff,
            browser: browser,
            hostingAccounts: hostingAccounts,
            quickOpen: QuickOpen(
                root: files.root,
                lister: fileLister,
                isExcluded: { [weak files] in files?.exclusionRoot(for: $0) != nil }
            )
        )
    }
}

/// Lists nothing: for assemblies that have no disk to read (Preview, tests).
struct NoProjectFileLister: ProjectFileLister {
    func listFiles(under root: String) async -> ProjectFileList { ProjectFileList(paths: []) }
}
