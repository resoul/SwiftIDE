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
    private(set) var integrationWindow: GitIntegrationWindowController?
    private var conflictTask: Task<Void, Never>?
    private var conflictID = UUID()
    private var confirmationTask: Task<Void, Never>?
    private var conflictEditors: [DocumentID: GitConflictEditorController] = [:]
    private let conflictTabID = DocumentID()
    private var standaloneConflict: GitConflictEditorController?
    var openConflictResult: ((String) async -> DocumentEditorController?)?
    private(set) var pullWindow: GitPullWindowController?
    private(set) var pushWindow: GitPushWindowController?
    private let gitBranches: GitBranchPickerViewController?
    private let gitDiff: GitDiffViewController?
    private let diffTabID = DocumentID()
    private var gitSubscription: UUID?
    private var lastGitOperationState = GitOperationState.idle
    private var gitEvents: GitRepositoryEvents?
    private var fileRefreshTask: Task<Void, Never>?
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

    init(
        files: ProjectFiles,
        layout: WorkspaceLayoutState = .init(),
        panels: [WorkspaceTool: WorkspacePanel] = [:],
        git: GitWorkspace? = nil
    ) {
        self.files = files
        self.layout = layout
        self.git = git
        gitChanges = git.map { GitChangesViewController(model: $0) }
        gitLog = git.map { GitLogViewController(model: $0) }
        gitBranches = git.map { GitBranchPickerViewController(model: $0) }
        gitDiff = git.map { GitDiffViewController(model: $0) }
        var providers = panels
        if let gitChanges {
            providers[.sourceControl] = WorkspacePanel(view: gitChanges.view, focusTarget: gitChanges.focusTarget)
        }

        if let gitLog { providers[.gitLog] = WorkspacePanel(view: gitLog.view, focusTarget: gitLog.focusTarget) }
        browser = ProjectFilesContainer(model: files, editor: area.view, layout: layout, panels: providers)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
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

            if id == conflictTabID { standaloneConflict?.stop(); standaloneConflict = nil; tabs.remove(id) }
            else if id == diffTabID { tabs.remove(id) } else { editors[id]?.requestClose() }
        }
        area.tabs.onMove = { [weak self] in self?.tabs.move($0, to: $1) }
        tabSubscription = tabs.subscribe { [weak self] in self?.renderSelection() }
        filesSubscription = files.subscribe { [weak self] in self?.presentTabs() }
        if let git {
            if let gitChanges {
                browser.addChild(gitChanges)
                gitChanges.openFile = { [weak self] in self?.openFile?($0) }
            }

            if let gitLog { browser.addChild(gitLog) }
            if let gitBranches { browser.addChild(gitBranches); shell.installProjectAccessory(gitBranches.view) }
            gitChanges?.resolveConflict = { [weak self] in self?.showConflict($0) }
            gitChanges?.confirmAction = { [weak self] in self?.confirmGitAction($0) }
            gitBranches?.onIntegrateRequested = { [weak self] kind, branch in
                self?.showIntegration(kind, target: branch)
            }
            gitBranches?.onPullRequested = { [weak self] remote, source in
                self?.showPull(remote: remote, source: source)
            }
            gitBranches?.onPushRequested = { [weak self] branch, remote in
                self?.showPush(branch: branch, remote: remote)
            }
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

        conflictEditors.removeValue(forKey: document.session.id)?.stop()
        document.onPresentationChange = nil
        document.onFileSaved = nil
        document.onActivate = nil
        tabs.remove(document.session.id)
        updatePresentation()
    }

    func select(_ id: DocumentID) {
        guard editors[id] != nil || id == diffTabID || id == conflictTabID else { return }

        tabs.select(id)
        window?.makeFirstResponder(area.focusTarget)
    }

    private func renderSelection() {
        let active = activeDocument
        let inspection = tabs.selected == diffTabID
        let conflict = tabs.selected == conflictTabID
            ? standaloneConflict
            : active.flatMap {
            conflictEditors[$0.session.id]
        }
        let content: NSViewController? = conflict ?? (inspection ? gitDiff : active)
        let focus = inspection ? gitDiff?.text : active?.focusTarget
        let switching = area.active !== content
        if switching {
            (area.active as? GitConflictEditorController)?.document?.deactivate()
            (area.active as? GitConflictEditorController)?.detachEditor()
            (area.active as? DocumentEditorController)?.deactivate()
            window?.makeFirstResponder(nil)
            area.show(content, focusTarget: focus)
            conflict?.attachEditor()
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
        shell.present(
            detail: tabs.selected == diffTabID ? "Read-only Git diff" : activeDocument?.detail,
            status: activeDocument?.status ?? (tabs.selected == diffTabID
                          ? git?.diffState.explanation
                          : "Open a file to begin editing") ?? ""
        )
        presentTabs()
    }

    private func presentTabs() {
        let presentations = tabs.order.compactMap { id -> DocumentTabPresentation? in
            if id == conflictTabID {
                return DocumentTabPresentation(
                    id: id,
                    name: "Resolve · " + ((standaloneConflict?.context.conflict.path ?? "Conflict") as NSString)
                    .lastPathComponent,
                    path: standaloneConflict?.context.conflict.path ?? "Git conflict"
                )
            }

            if id == diffTabID {
                return DocumentTabPresentation(
                    id: id,
                    name: "Diff · " + ((git?.comparison?.path ?? "Changes") as NSString)
                                               .lastPathComponent,
                    path: git?.comparison?.title ?? "Git diff"
                )
            }

            guard let document = editors[id] else { return nil }

            var decoration = files.decoration(for: document.session.path)
            decoration.isUnsaved = document.session.isDirty

            return DocumentTabPresentation(
                id: document.session.id,
                name: document.displayName,
                path: document.session.path,
                decoration: decoration
            )
        }
        area.tabs.present(presentations, selected: tabs.selected)
    }

    private func presentGit() {
        guard let git else { return }

        presentGitNotification(git)

        if let snapshot = git.snapshot, snapshot.capturedAt != presentedSnapshotDate {
            presentedSnapshotDate = snapshot.capturedAt
            files.applyGitSnapshot(snapshot)
            files.hasIgnoreInformation = true
            if watchedRepository != snapshot.repository {
                gitEvents?.stop()
                watchedRepository = snapshot.repository
                gitEvents = GitRepositoryEvents(repository: snapshot.repository) { [weak self, weak git] in
                    Task { @MainActor in
                        git?.scheduleRefresh()
                        self?.scheduleFileRefresh()
                    }
                }
                git.liveUpdatesAvailable = gitEvents?.isActive
            }
        }

        files.statusExplanation = git.explanation
        updatePresentation()
    }

    private func scheduleFileRefresh() {
        fileRefreshTask?.cancel()
        fileRefreshTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            guard let self, !closing, !Task.isCancelled else { return }

            files.refreshListings()
            fileRefreshTask = nil
        }
    }

    private func presentGitNotification(_ git: GitWorkspace) {
        let previous = lastGitOperationState
        lastGitOperationState = git.operationState
        guard previous.isBusy, !git.operationState.isBusy else { return }

        let kind: WorkspaceNotificationKind
        let suffix: String
        let message: String
        switch git.operationState {
        case .succeeded:
            kind = .success; suffix = " completed"
            message = "See Source Control for the current repository state."
        case .failed(let reason):
            kind = .error; suffix = " stopped"
            message = String(reason.prefix(600))
        case .cancelled:
            kind = .information; suffix = " cancelled"
            message = "Changes already made are retained. See Source Control for details."
        default: return
        }
        shell.notifications.post(WorkspaceNotification(
            id: "git.operation",
            kind: kind,
            title: git.operationTitle + suffix,
            message: message,
            actions: [.init(title: "Show details…", perform: { [weak self] in self?.shell.select(.sourceControl) })]
        ))
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
        fileRefreshTask?.cancel(); fileRefreshTask = nil
        conflictTask?.cancel(); conflictID = UUID(); confirmationTask?.cancel()
        for controller in conflictEditors.values { controller.stop() }; conflictEditors = [:]
        standaloneConflict?.stop(); standaloneConflict = nil
        integrationWindow?.dismiss(); pushWindow?.dismiss(); pullWindow?.dismiss()
        git?.stop(); gitChanges?.disconnect(); gitLog?.disconnect(); gitBranches?.disconnect(); gitDiff?.disconnect()
        files.onRefresh = nil
        files.stop()
        shell.notifications.removeAll()
        browser.disconnect()
        onClose?()
    }

    @objc func closeDocument(_ sender: Any?) {
        if tabs.selected == conflictTabID {
            standaloneConflict?.stop()
            standaloneConflict = nil
            tabs.remove(conflictTabID)

            return
        }

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
    @objc func askAboutProjectConfigurationAgain(_ sender: Any?) {
        activeDocument?.askAboutProjectConfigurationAgain(sender)
    }
    @objc func showFiles(_ sender: Any?) { shell.select(.files) }
    @objc func toggleFocusEditor(_ sender: Any?) { shell.toggleFocusEditor(sender) }
    @objc func resetWorkspaceLayout(_ sender: Any?) { shell.resetWorkspaceLayout(sender) }
    @objc func showSearch(_ sender: Any?) {}
    @objc func showSourceControl(_ sender: Any?) { if git != nil { shell.select(.sourceControl) } }
    @objc func showGitLog(_ sender: Any?) { if git != nil { shell.select(.gitLog) } }
    @objc func refreshGit(_ sender: Any?) { git?.refresh() }
    func showConflict(_ change: GitChange) {
        guard let git, git.canMutate, let snapshot = git.snapshot, let reader = git.conflictReader else { return }

        conflictTask?.cancel(); conflictID = UUID()
        let token = conflictID
        conflictTask = Task { [weak self] in
            do {
                let data = try await reader.conflict(in: snapshot, path: change.path)
                try Task.checkCancellation()
                guard let self, conflictID == token, !closing, window?.isVisible == true else { return }

                let document = data.workingText != nil && data.supportsResolution
                    ? await openConflictResult?(data.repository.absolutePath(data.path))
                    : nil
                try Task.checkCancellation()
                guard conflictID == token, !closing else { return }

                let controller = GitConflictEditorController(workspace: git, conflict: data, document: document)
                controller.reportError = { [weak self] in self?.showGitError($0) }
                controller.context.restoreStage = { [weak self] stage in
                    self?.confirmGitAction(.resolveConflict(data, .restoreStage(stage)))
                }
                controller.context.resolveDeleted = { [weak self] in
                    self?.confirmGitAction(.resolveConflict(data, .delete))
                }
                controller.context.reopen = { [weak self] in
                    if let current = git.snapshot?.changes
                        .first(where: { $0.path == data.path && $0.decoration.isConflict }) {
                        self?.showConflict(current)
                    }
                }
                controller.context.openResult = { [weak self] in
                    self?.openFile?(data.repository.absolutePath(data.path))
                }
                controller.context.closePreview = { [weak self, weak controller, weak document] in
                    guard let self else { return }

                    if let document {
                        conflictEditors[document.session.id] = nil
                        controller?.stop()
                        renderSelection()
                    }
                    else { standaloneConflict?.stop(); standaloneConflict = nil; tabs.remove(conflictTabID) }
                }
                if let document {
                    if standaloneConflict?.context.conflict.path == data.path,
                       standaloneConflict?.context.conflict.repository == data.repository {
                        if area.active === standaloneConflict { area.show(nil) }
                        standaloneConflict?.stop(); standaloneConflict = nil; tabs.remove(conflictTabID)
                    }

                    if let old = conflictEditors.removeValue(forKey: document.session.id) {
                        if area.active === old { area.show(nil) }
                        old.stop()
                    }

                    conflictEditors[document.session.id] = controller
                    tabs.open(document.session.id); renderSelection()
                } else {
                    if area.active === standaloneConflict { area.show(nil) }
                    standaloneConflict?.stop()
                    standaloneConflict = controller
                    tabs.open(conflictTabID)
                    renderSelection()
                }
            } catch { if !Task.isCancelled { self?.showGitError(error.localizedDescription) } }
        }
    }
    private func showGitError(_ message: String) {
        guard let window, window.isVisible, window.attachedSheet == nil else { return }

        let alert = NSAlert(); alert.messageText = "Git action unavailable"; alert.informativeText = message
        alert.addButton(withTitle: "OK"); alert.beginSheetModal(for: window)
    }
    func confirmGitAction(_ action: GitAction) {
        guard let git, git.canMutate, let window, window.attachedSheet == nil else { return }

        let alert = NSAlert(); alert.messageText = action.title + "?"
        switch action {
        case .abortIntegration(let status):
            let head = status.originalHead.map { String($0.prefix(12)) } ?? "unknown"
            alert.informativeText = """
            Restores the original Git state (\(head)). On-disk resolution edits made after the operation began may be \
            discarded. Unsaved documents still require Save or Cancel.
            """
        case .skipRebase(let status):
            let commit = status.stoppedCommit.map { String($0.prefix(12)) } ?? "current step"
            alert.informativeText = """
            Drops the current replayed commit (\(commit)) from the rewritten branch. Staged resolution edits for this \
            step may be discarded; remaining commits still replay. Unsaved documents require Save or Cancel.
            """
        case .resolveConflict(let conflict, .delete):
            alert.informativeText = """
            Deletes “\(conflict.path)” from disk and stages its deletion as the resolution. Unsaved documents require \
            Save or Cancel; a changed working file must be reviewed again.
            """
        case .resolveConflict(let conflict, .restoreStage(let stage)):
            alert.informativeText = """
            Replaces “\(conflict.path)” on disk with the reviewed stage \(stage) blob and executable mode. It does \
            not mark the file resolved. Save and reload the preview first if the working file has changed.
            """
        default: return
        }
        alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: action.title)
        confirmationTask?.cancel()
        confirmationTask = Task { [weak self] in
            let answer = await withTaskCancellationHandler { await alert.beginSheetModal(for: window) } onCancel: {
                Task { @MainActor in
                    if alert.window.sheetParent === window { window.endSheet(alert.window, returnCode: .abort) }
                }
            }
            guard let self, !closing, !Task.isCancelled, answer == .alertSecondButtonReturn else { return }

            git.perform(action)
        }
    }
    func showIntegration(_ kind: GitIntegrationKind, target: GitBranch? = nil) {
        guard integrationWindow == nil, let git, git.canMutate, git.conflictReader != nil,
              git.snapshot?.integration == nil,
              let window, window.attachedSheet == nil else { return }

        let controller = GitIntegrationWindowController(workspace: git, kind: kind)
        integrationWindow = controller; controller.onClosed = { [weak self] in self?.integrationWindow = nil }
        shell.select(.sourceControl); controller.present(on: window, target: target)
    }
    @objc func mergeGit(_ sender: Any?) { showIntegration(.merge) }
    @objc func rebaseGit(_ sender: Any?) { showIntegration(.rebase) }
    @objc func continueGit(_ sender: Any?) { shell.select(.sourceControl); gitChanges?.continueOperation() }
    @objc func abortGit(_ sender: Any?) {
        if let status = git?.snapshot?.integration { confirmGitAction(.abortIntegration(status)) }
    }
    @objc func skipGit(_ sender: Any?) {
        if let status = git?.snapshot?.integration { confirmGitAction(.skipRebase(status)) }
    }
    func showPull(remote: String? = nil, source: String? = nil) {
        guard pullWindow == nil, let git, git.canMutate, git.pullPlanner != nil,
              let window, window.attachedSheet == nil else { return }

        let controller = GitPullWindowController(workspace: git)
        pullWindow = controller
        controller.onClosed = { [weak self] in self?.pullWindow = nil }
        shell.select(.sourceControl)
        controller.present(on: window, remote: remote, source: source)
    }
    @objc func pullGit(_ sender: Any?) { showPull() }
    func showPush(branch: GitBranch? = nil, remote: String? = nil) {
        guard pushWindow == nil, let git, git.canMutate, git.pushPlanner != nil,
              let window, window.attachedSheet == nil else { return }

        let controller = GitPushWindowController(workspace: git)
        pushWindow = controller
        controller.onClosed = { [weak self] in self?.pushWindow = nil }
        shell.select(.sourceControl)
        controller.present(on: window, branch: branch?.reference, remote: remote)
    }
    @objc func pushGit(_ sender: Any?) { showPush() }
    @objc func fetchGit(_ sender: Any?) { gitBranches?.showRemoteSelection() }
    @objc func commitGit(_ sender: Any?) { shell.select(.sourceControl); gitChanges?.focusCommitMessage() }
    @objc func cancelGit(_ sender: Any?) { git?.cancelOperation() }
    @objc func showTerminal(_ sender: Any?) {}
    @objc func showAssistant(_ sender: Any?) {}
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(mergeGit(_:)) || item.action == #selector(rebaseGit(_:)) {
            return git?.canMutate == true && git?.conflictReader != nil && git?.snapshot?.integration == nil && git?
                .snapshot?.branch != nil && git?.snapshot?.head != nil
        }

        if item.action == #selector(continueGit(_:)) {
            return git?.canMutate == true && git?.snapshot?.integration != nil && git?.snapshot?.integration?
                .kind != .other && git?.snapshot?.changes
                .contains(where: { $0.decoration.isConflict }) == false &&
                (git?.snapshot?.integration?.kind != .rebase || git?.snapshot?.integration?.stoppedCommit == nil || git?
                .snapshot?.changes
                .contains(where: { !$0.decoration.index.isEmpty && !$0.decoration.isConflict }) == true)
        }

        if item.action == #selector(abortGit(_:)) {
            return git?.canMutate == true && git?.snapshot?.integration != nil && git?.snapshot?.integration?
                .kind != .other
        }

        if item.action == #selector(skipGit(_:)) {
            return git?.canMutate == true && git?.snapshot?.integration?.kind == .rebase
        }

        if item.action == #selector(pullGit(_:)) {
            return git?.canMutate == true && git?.pullPlanner != nil && git?.snapshot?.remotes.isEmpty == false && git?
                .snapshot?.branch != nil && git?.snapshot?.head != nil
        }

        if item.action == #selector(pushGit(_:)) {
            return git?.canMutate == true && git?.pushPlanner != nil && git?.snapshot?.remotes.isEmpty == false && git?
                .snapshot?.branches.contains(where: { !$0.isRemote }) == true
        }

        if item.action == #selector(fetchGit(_:)) {
            return git?.canMutate == true && git?.snapshot?.remotes.isEmpty == false
        }

        if item.action == #selector(commitGit(_:)) { return git?.canMutate == true }
        if item.action == #selector(cancelGit(_:)) { return git?.operationState.isBusy == true }
        if item.action == #selector(refreshGit(_:)) { return git != nil && git?.operationState.isBusy == false }
        if item.action == #selector(showSourceControl(_:)) { return git != nil }
        if item.action == #selector(showGitLog(_:)) || item.action == #selector(refreshGit(_:)) { return git != nil }
        if [#selector(showSearch(_:)), #selector(showTerminal(_:)), #selector(showAssistant(_:))]
            .contains(item.action) {
            return false
        }

        if [
            #selector(showFiles(_:)),
            #selector(toggleFocusEditor(_:)),
            #selector(resetWorkspaceLayout(_:)),
            #selector(closeDocument(_:))
        ].contains(item.action) {
            return true
        }

        return activeDocument?.validateMenuItem(item) ?? false
    }
}
