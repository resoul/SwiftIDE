import AppKit
import ChatUI
import IDEApplication
import WorkspaceUI

/// A ready project UI graph. Shared app services are borrowed; project models and panels stop together.
@MainActor
final class WorkspaceModule {
    let window: NSWindow
    let files: ProjectFiles
    let layout: WorkspaceLayoutState
    let tabs: DocumentTabs
    let area: EditorAreaViewController
    let git: GitWorkspace?
    let agent: AgentSession
    let chat: ChatPanelViewController
    let gitChanges: GitChangesViewController?
    let gitLog: GitLogViewController?
    let gitBranches: GitBranchPickerViewController?
    let gitDiff: GitDiffViewController?
    let browser: ProjectFilesContainer
    let hostingAccounts: GitHostingAccounts?
    let quickOpen: QuickOpen
    private var isStopped = false

    init(
        window: NSWindow,
        files: ProjectFiles,
        layout: WorkspaceLayoutState,
        tabs: DocumentTabs,
        area: EditorAreaViewController,
        git: GitWorkspace?,
        agent: AgentSession,
        chat: ChatPanelViewController,
        gitChanges: GitChangesViewController?,
        gitLog: GitLogViewController?,
        gitBranches: GitBranchPickerViewController?,
        gitDiff: GitDiffViewController?,
        browser: ProjectFilesContainer,
        hostingAccounts: GitHostingAccounts?,
        quickOpen: QuickOpen
    ) {
        self.window = window
        self.files = files
        self.layout = layout
        self.tabs = tabs
        self.area = area
        self.git = git
        self.agent = agent
        self.chat = chat
        self.gitChanges = gitChanges
        self.gitLog = gitLog
        self.gitBranches = gitBranches
        self.gitDiff = gitDiff
        self.browser = browser
        self.hostingAccounts = hostingAccounts
        self.quickOpen = quickOpen
    }

    /// The window controller cancels its operation flows first, then disconnects this project scope.
    func stop() {
        guard !isStopped else { return }

        isStopped = true
        quickOpen.stop()
        agent.stop()
        chat.disconnect()
        git?.stop()
        gitChanges?.disconnect()
        gitLog?.disconnect()
        gitBranches?.disconnect()
        gitDiff?.disconnect()
        files.onRefresh = nil
        files.stop()
        browser.workspace.notifications.removeAll()
        browser.disconnect()
    }
}
