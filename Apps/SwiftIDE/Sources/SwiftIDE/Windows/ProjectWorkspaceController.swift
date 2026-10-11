import AppKit
import IDEApplication
import IDEDomain
import WorkspaceUI
import GitInfrastructure

/// One real project window, one shell/tree and content-owned document tabs.
@MainActor
final class ProjectWorkspaceController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    let files: ProjectFiles
    let layout: WorkspaceLayoutState
    let tabs = DocumentTabs()
    let area = EditorAreaViewController()
    let git: GitWorkspace?
    private let gitChanges: GitChangesViewController?
    private let gitLog: GitLogViewController?
    private let gitBranches: GitBranchPickerViewController?
    private let gitDiff: GitDiffViewController?
    private let diffTabID = DocumentID()
    private var gitSubscription: UUID?
    private var gitEvents: GitRepositoryEvents?
    private var watchedRepository: GitRepository?
    private var presentedSnapshotDate: Date?
    var documents: [DocumentEditorController] { tabs.order.compactMap { editors[$0] } }
    var activeDocument: DocumentEditorController? { tabs.selected.flatMap { editors[$0] } }
    var openFile: ((String) -> Void)?
    var onClose: (() -> Void)?
    var onRequestClose: (() -> Void)?
    var onReleaseDocument: ((DocumentEditorController) -> Void)?
    var projectMenu: (() -> NSMenu)? { didSet { browser.shell.projectMenu = projectMenu } }
    var shell: WorkspaceShellViewController { browser.shell }
    private var editors: [DocumentID: DocumentEditorController] = [:]
    private var closing = false
    private let browser: ProjectFilesContainer
    private var filesSubscription: UUID?
    private var tabSubscription: UUID?

    init(files: ProjectFiles, layout: WorkspaceLayoutState = .init(), panels: [WorkspaceTool: WorkspacePanel] = [:], git: GitWorkspace? = nil) {
        self.files = files
        self.layout = layout
        self.git = git
        gitChanges = git.map { GitChangesViewController(model: $0) }
        gitLog = git.map { GitLogViewController(model: $0) }
        gitBranches = git.map { GitBranchPickerViewController(model: $0) }
        gitDiff = git.map { GitDiffViewController(model: $0) }
        var providers = panels
        if let gitChanges { providers[.sourceControl] = WorkspacePanel(view: gitChanges.view, focusTarget: gitChanges.focusTarget) }
        if let gitLog { providers[.gitLog] = WorkspacePanel(view: gitLog.view, focusTarget: gitLog.focusTarget) }
        browser = ProjectFilesContainer(model: files, editor: area.view, layout: layout, panels: providers)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered,
                              defer: false)
        window.title = (files.root as NSString).lastPathComponent
        window.representedURL = URL(fileURLWithPath: files.root)
        window.contentViewController = browser
        window.minSize = NSSize(width: 900, height: 560)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.center()
        super.init(window: window)
        window.delegate = self
        browser.addChild(area)
        browser.files.openFile = { [weak self] in self?.openFile?($0) }
        area.tabs.onSelect = { [weak self] in self?.select($0) }
        area.tabs.onClose = { [weak self] id in
            guard let self else { return }

            if id == diffTabID { tabs.remove(id) } else { editors[id]?.requestClose() }
        }
        area.tabs.onMove = { [weak self] in self?.tabs.move($0, to: $1) }
        tabSubscription = tabs.subscribe { [weak self] in self?.renderSelection() }
        filesSubscription = files.subscribe { [weak self] in self?.presentTabs() }
        if let git {
            if let gitChanges { browser.addChild(gitChanges); gitChanges.openFile = { [weak self] in self?.openFile?($0) } }
            if let gitLog { browser.addChild(gitLog) }
            if let gitBranches { browser.addChild(gitBranches); shell.installProjectAccessory(gitBranches.view) }
            gitBranches?.onActionStarted = { [weak self] in self?.shell.select(.sourceControl) }
            gitBranches?.onViewHistory = { [weak self] in self?.shell.select(.gitLog) }
            git.onInspect = { [weak self] in
                guard let self else { return }

                tabs.open(diffTabID)
            }
            files.onRefresh = { [weak git] in git?.refresh() }
            gitSubscription = git.subscribe { [weak self] in self?.presentGit() }
            git.refresh()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func add(_ document: DocumentEditorController) {
        guard editors[document.session.id] == nil, let window else { return }

        editors[document.session.id] = document
        document.onPresentationChange = { [weak self] in self?.updatePresentation() }
        document.onFileSaved = { [weak self] in self?.files.refresh() }
        document.onActivate = { [weak self, weak document] in
            if let document { self?.select(document.session.id) }
        }
        document.bind(to: window)
        tabs.open(document.session.id)
        document.showDocument()
    }

    func remove(_ document: DocumentEditorController) {
        guard editors.removeValue(forKey: document.session.id) != nil else { return }

        document.onPresentationChange = nil
        document.onFileSaved = nil
        document.onActivate = nil
        tabs.remove(document.session.id)
        updatePresentation()
    }

    func select(_ id: DocumentID) {
        guard editors[id] != nil || id == diffTabID else { return }

        tabs.select(id)
        window?.makeFirstResponder(area.focusTarget)
    }

    private func renderSelection() {
        let active = activeDocument
        let inspection = tabs.selected == diffTabID
        let content: NSViewController? = inspection ? gitDiff : active
        let focus = inspection ? gitDiff?.text : active?.focusTarget
        let switching = area.active !== content
        if switching {
            (area.active as? DocumentEditorController)?.deactivate()
            window?.makeFirstResponder(nil)
            area.show(content, focusTarget: focus)
            area.view.layoutSubtreeIfNeeded()
        }

        shell.editorFocus = focus
        updatePresentation()
        if switching, let focus { window?.makeFirstResponder(focus) }
    }

    private func updatePresentation() {
        let unsaved = Set(documents.filter { $0.session.isDirty && !$0.session.isUntitled }.map { $0.session.path })
        if files.unsavedPaths != unsaved { files.unsavedPaths = unsaved }
        window?.isDocumentEdited = documents.contains { $0.session.isDirty }
        window?.subtitle = activeDocument?.status ?? ""
        shell.present(detail: tabs.selected == diffTabID ? "Read-only Git diff" : activeDocument?.detail,
                      status: activeDocument?.status ?? (tabs.selected == diffTabID ? git?.diffState.explanation : "Open a file to begin editing") ?? "")
        presentTabs()
    }

    private func presentTabs() {
        let presentations = tabs.order.compactMap { id -> DocumentTabPresentation? in
            if id == diffTabID {
                return DocumentTabPresentation(id: id,
                                               name: "Diff · " + ((git?.comparison?.path ?? "Changes") as NSString).lastPathComponent,
                                               path: git?.comparison?.title ?? "Git diff")
            }

            guard let document = editors[id] else { return nil }

            var decoration = files.decoration(for: document.session.path)
            decoration.isUnsaved = document.session.isDirty

            return DocumentTabPresentation(id: document.session.id, name: document.displayName, path: document.session.path, decoration: decoration)
        }
        area.tabs.present(presentations, selected: tabs.selected)
    }

    private func presentGit() {
        guard let git else { return }

        if let snapshot = git.snapshot, snapshot.capturedAt != presentedSnapshotDate {
            presentedSnapshotDate = snapshot.capturedAt
            files.applyGitSnapshot(snapshot)
            files.hasIgnoreInformation = true
            files.refreshListings()
            if watchedRepository != snapshot.repository {
                gitEvents?.stop()
                watchedRepository = snapshot.repository
                gitEvents = GitRepositoryEvents(repository: snapshot.repository) { [weak git] in
                    Task { @MainActor in git?.scheduleRefresh() }
                }
                git.liveUpdatesAvailable = gitEvents?.isActive
            }
        }

        files.statusExplanation = git.explanation
        updatePresentation()
    }

    func showWorkspace() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(area.focusTarget)
    }

    func releaseDocuments() {
        closing = true
        for document in documents {
            remove(document)
            onReleaseDocument?(document)
        }
        window?.close()
    }

    /// The caller reconciles unsaved documents before entering; no suspension after the decision.
    func closeProject() {
        closing = true
        for document in documents { document.close() }
        window?.close()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !closing, !documents.isEmpty else { return true }

        onRequestClose?()

        return false
    }

    func windowWillClose(_ notification: Notification) {
        if let filesSubscription { files.unsubscribe(filesSubscription) }
        if let tabSubscription { tabs.unsubscribe(tabSubscription) }
        if let gitSubscription { git?.unsubscribe(gitSubscription) }
        gitEvents?.stop(); gitEvents = nil
        git?.stop(); gitChanges?.disconnect(); gitLog?.disconnect(); gitBranches?.disconnect(); gitDiff?.disconnect()
        files.onRefresh = nil
        files.stop()
        browser.disconnect()
        onClose?()
    }

    @objc func closeDocument(_ sender: Any?) {
        if tabs.selected == diffTabID { tabs.remove(diffTabID); return }
        if let activeDocument { activeDocument.requestClose() } else { window?.performClose(sender) }
    }
    @objc func saveDocument(_ sender: Any?) { activeDocument?.saveDocument(sender) }
    @objc func saveDocumentAs(_ sender: Any?) { activeDocument?.saveDocumentAs(sender) }
    @objc func selectLanguage(_ sender: NSMenuItem) { activeDocument?.selectLanguage(sender) }
    @objc func showQuickHelp(_ sender: Any?) { activeDocument?.showQuickHelp(sender) }
    @objc func jumpToDefinition(_ sender: Any?) { activeDocument?.jumpToDefinition(sender) }
    @objc func allowProjectConfiguration(_ sender: Any?) { activeDocument?.allowProjectConfiguration(sender) }
    @objc func disallowProjectConfiguration(_ sender: Any?) { activeDocument?.disallowProjectConfiguration(sender) }
    @objc func askAboutProjectConfigurationAgain(_ sender: Any?) { activeDocument?.askAboutProjectConfigurationAgain(sender) }
    @objc func showPreviewFiles(_ sender: Any?) { shell.select(.files) }
    @objc func toggleFocusEditor(_ sender: Any?) { shell.toggleFocusEditor(sender) }
    @objc func resetWorkspaceLayout(_ sender: Any?) { shell.resetWorkspaceLayout(sender) }
    @objc func showPreviewSearch(_ sender: Any?) {}
    @objc func showPreviewSourceControl(_ sender: Any?) { if git != nil { shell.select(.sourceControl) } }
    @objc func showGitLog(_ sender: Any?) { if git != nil { shell.select(.gitLog) } }
    @objc func refreshGit(_ sender: Any?) { git?.refresh() }
    @objc func commitGit(_ sender: Any?) { shell.select(.sourceControl); gitChanges?.focusCommitMessage() }
    @objc func cancelGit(_ sender: Any?) { git?.cancelOperation() }
    @objc func showPreviewTerminal(_ sender: Any?) {}
    @objc func showPreviewAssistant(_ sender: Any?) {}
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(commitGit(_:)) { return git?.canMutate == true }
        if item.action == #selector(cancelGit(_:)) { return git?.operationState.isBusy == true }
        if item.action == #selector(refreshGit(_:)) { return git != nil && git?.operationState.isBusy == false }
        if item.action == #selector(showPreviewSourceControl(_:)) { return git != nil }
        if item.action == #selector(showGitLog(_:)) || item.action == #selector(refreshGit(_:)) { return git != nil }
        if [#selector(showPreviewSearch(_:)), #selector(showPreviewTerminal(_:)), #selector(showPreviewAssistant(_:))].contains(item.action) { return false }
        if [#selector(showPreviewFiles(_:)), #selector(toggleFocusEditor(_:)), #selector(resetWorkspaceLayout(_:)), #selector(closeDocument(_:))].contains(item.action) { return true }

        return activeDocument?.validateMenuItem(item) ?? false
    }
}
