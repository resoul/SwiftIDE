import AppKit
import IDEApplication
import IDEDomain

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let composition: AppCompositionRoot
    private var documents: [DocumentEditorController] = []
    private let gitCheckoutPrompt: ((DocumentSession) async -> GitCheckoutDocuments.Decision)?
    private lazy var gitCheckout = GitCheckoutCoordinator(
        documents: { [weak self] in self?.documents ?? [] },
        prompt: gitCheckoutPrompt
    )
    private var standalone: [DocumentID: WorkspaceWindowController] = [:]
    private var projects: [String: ProjectWorkspaceController] = [:]
    private var closingProjects: Set<String> = []
    private var openingFolders: Set<String> = []
    private var isTerminating = false
    private let recoveryPrompt: ((RecoveryCandidate) -> Bool)?
    private(set) var cloneWindow: GitCloneWindowController?
    private(set) var welcome: WelcomeWindowController?
    private(set) var settingsWindow: SettingsWindowController?

    init(
        composition: AppCompositionRoot = AppCompositionRoot(),
        recoveryPrompt: ((RecoveryCandidate) -> Bool)? = nil,
        gitCheckoutPrompt: ((DocumentSession) async -> GitCheckoutDocuments.Decision)? = nil
    ) {
        self.composition = composition
        self.recoveryPrompt = recoveryPrompt
        self.gitCheckoutPrompt = gitCheckoutPrompt
        super.init()
    }

    /// Where the user jumped from, for Go Back.
    private var history = NavigationHistory()
    private lazy var unsavedChanges = UnsavedChangesCoordinator(
        prompt: { [unowned self] session in
            await controller(for: session)?.promptForUnsavedChanges() ?? .cancel
        },
        save: { [unowned self] session in
            await controller(for: session)?.save() ?? false
        }
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        composition.appearance.applyStored()
        MainMenu.install()
        NSWindow.allowsAutomaticWindowTabbing = false
        NSApp.activate()
        Task { await start() }
    }

    /// Welcome is the starting surface; recovering work may then open real document windows.
    func start() async {
        if documents.isEmpty && projects.isEmpty { showWelcome(nil) }
        await restoreUnsavedWork()
    }

    @objc func showWelcome(_ sender: Any?) {
        if welcome == nil {
            let controller = WelcomeWindowController(model: composition.recentProjects)
            controller.content.cloneRepository = { [weak self] in self?.cloneRepository(nil) }
            controller.content.openFolder = { [weak self] in self?.openFolder(nil) }
            controller.content.openProject = { [weak self] path in Task { await self?.openProjectFolder(path: path) } }
            controller.content.locateProject = { [weak self] path in self?.locateProject(path: path) }
            controller.onClose = { [weak self] in self?.cloneWindow?.dismiss() }
            welcome = controller
        }

        welcome?.showWindow(nil)
    }

    @objc func cloneRepository(_ sender: Any?) {
        showWelcome(nil)
        guard cloneWindow == nil, let parent = welcome?.window, parent.attachedSheet == nil else { return }

        let model = composition.makeGitClone()
        let controller = GitCloneWindowController(model: model)
        cloneWindow = controller
        controller.onClosed = { [weak self] in self?.cloneWindow = nil }
        model.onSuccess = { [weak self, weak controller] path in
            controller?.dismiss()
            Task { await self?.openProjectFolder(path: path) }
        }
        controller.present(on: parent)
    }

    private func returnToWelcomeIfNeeded() {
        if !isTerminating && documents.isEmpty && projects.isEmpty { showWelcome(nil) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showWelcome(nil) }

        return true
    }

    /// Back in front: the selected Xcode, the language server's configuration files and the package
    /// manifests may have changed meanwhile, and none of them tells (ADR-034).
    func applicationDidBecomeActive(_ notification: Notification) {
        if !documents.isEmpty || !projects.isEmpty { Task { await composition.languageServices.refreshEnvironment() } }
        for project in projects.values { project.files.refresh() }
        if welcome?.window?.isVisible == true { composition.recentProjects.refreshAvailability() }
    }

    /// Leaving for the background is the moment a user may force-quit or lose power: the unsaved
    /// text is written now instead of waiting for the next pause in typing.
    func applicationDidResignActive(_ notification: Notification) {
        Task { [documents] in
            for window in documents { await window.flushRecovery() }
        }
    }

    /// AppKit does not consult windows when the app quits, so unsaved documents are checked here
    /// with the same procedure the documents use. Quitting waits for the answers.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard documents.contains(where: { $0.session.isDirty }) else { isTerminating = true; return .terminateNow }

        Task {
            // The documents are read again after every answer, not captured once.
            // The user's choice to lose changes must also remove their recovery copies, or they are
            // offered back at the next start. That takes time during which more can be typed, so it
            // is part of the decision: the procedure checks again afterwards, and nothing
            // suspends between its final check and this reply.
            let allowed = await unsavedChanges.canQuit(
                documents: { [unowned self] in documents.map(\.session) },
                release: { [unowned self] sessions in
                    for session in sessions { await controller(for: session)?.withdrawRecovery() }
                },
                reinstate: { [unowned self] sessions in
                    for session in sessions { controller(for: session)?.resumeRecovery() }
                }
            )
            isTerminating = allowed
            NSApp.reply(toApplicationShouldTerminate: allowed)
        }

        return .terminateLater
    }

    /// Servers end when their pipes close, but not waiting for that keeps them from outliving us.
    func applicationWillTerminate(_ notification: Notification) {
        cloneWindow?.dismiss()
        composition.languageServices.terminateAll()
        composition.recentProjects.stopChecking()
        welcome?.content.disconnect()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    @objc func newDocument(_ sender: Any?) {
        show(composition.makeUntitledDocument(), in: activeProject)
    }

    @objc func showSettings(_ sender: Any?) {
        if settingsWindow == nil { settingsWindow = SettingsWindowController(settings: composition.appearance) }
        settingsWindow?.showWindow(nil)
        settingsWindow?.window?.makeKeyAndOrderFront(nil)
    }

    @objc func openDocument(_ sender: Any?) {
        chooseFiles(startingAt: nil)
    }

    /// File ▸ Open Folder… uses the existing explicit-root policy and opens a real Files browser.
    @objc func openFolder(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Open Folder"
        guard panel.runModal() == .OK, let folder = panel.url else { return }

        Task { await openProjectFolder(path: folder.path) }
    }

    /// All user folder entry points share validation, history and focus behaviour.
    @discardableResult
    func openProjectFolder(path: String, replacing oldPath: String? = nil) async -> ProjectWorkspaceController? {
        guard openingFolders.insert(path).inserted else { return nil }

        defer { openingFolders.remove(path) }
        // An already-open project can still be focused even when its folder was removed on disk.
        if let existing = projects[path], oldPath == nil {
            existing.showWorkspace()
            composition.recentProjects.opened(canonicalPath: existing.files.root, checked: false)
            welcome?.hide()

            return existing
        }

        let state = await composition.folderChecker.check(path: path)
        guard !Task.isCancelled, !isTerminating else { return nil }

        composition.recentProjects.checked(path, state: state)
        guard case .available(let root) = state else {
            showFolderFailure(path: path, state: state)

            return nil
        }

        let project = openProject(path: root)
        project.showWorkspace()
        composition.recentProjects.opened(canonicalPath: root, replacing: oldPath)
        welcome?.hide()

        return project
    }

    private func locateProject(path: String) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Locate Folder"
        guard panel.runModal() == .OK, let folder = panel.url else { return }

        Task { await openProjectFolder(path: folder.path, replacing: path) }
    }

    private func showFolderFailure(path: String, state: ProjectFolderAvailability) {
        let alert = NSAlert()
        alert.messageText = "Could not open “\((path as NSString).lastPathComponent)”"
        if case .unavailable(let reason) = state { alert.informativeText = reason }
        else { alert.informativeText = "The project folder could not be found." }

        alert.addButton(withTitle: "Locate Folder…")
        alert.addButton(withTitle: "Cancel")
        // Missing is actionable, but does not delete a recent record or grant configuration trust.
        if let window = welcome?.window, window.isVisible {
            alert.beginSheetModal(for: window) { [weak self] answer in
                if answer == .alertFirstButtonReturn { self?.locateProject(path: path) }
            }
        } else if alert.runModal() == .alertFirstButtonReturn {
            locateProject(path: path)
        }
    }

    @discardableResult
    func openProject(path: String) -> ProjectWorkspaceController {
        let root = DocumentPath.canonical(path)
        if let project = projects[root] { return project }

        composition.languageServices.contexts.open(folder: root)
        let project = ProjectWorkspaceController(
            files: composition.makeProjectFiles(root: root),
            layout: composition.makeWorkspaceLayout(root: root),
            git: composition.makeGitWorkspace(root: root)
        )
        project.git?.prepareCheckout = { [weak self] repository in
            await self?.gitCheckout.prepare(repository) ?? false
        }
        project.git?.checkoutFinished = { [weak self] repository in self?.gitCheckout.finish(repository) }
        projects[root] = project
        project.projectMenu = { [weak self] in self?.projectSwitcherMenu() ?? NSMenu() }
        project.openConflictResult = { [weak self, weak project] path in
            guard let self, let project else { return nil }

            await open(path: path, in: project)

            return project.documents.first { $0.session.path == DocumentPath.canonical(path) }
        }
        project.openFile = { [weak self, weak project] path in Task { await self?.open(path: path, in: project) } }
        project.onRequestClose = { [weak self, weak project] in
            if let project { Task { await self?.closeProject(project) } }
        }
        project.onReleaseDocument = { [weak self] in self?.hostStandalone($0) }
        project.onClose = { [weak self] in
            guard let self else { return }

            projects[root] = nil
            composition.languageServices.contexts.close(folder: root)
            composition.recentProjects.setOpenRoots(Set(projects.keys))
            returnToWelcomeIfNeeded()
        }
        composition.recentProjects.setOpenRoots(Set(projects.keys))
        // A file already open keeps its session and editor; it becomes a tab of this explicit root.
        for document in documents
            where composition.languageServices.contexts.context(forFile: document.session.path)?.root == root {
            for old in projects.values where old !== project && old.documents.contains(where: { $0 === document }) {
                old.remove(document)
            }
            standalone.removeValue(forKey: document.session.id)?.releaseDocument()
            project.add(document)
        }

        return project
    }

    func projectSwitcherMenu() -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, path: String) {
            let item = NSMenuItem(title: title, action: #selector(openProjectFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = path
            item.toolTip = path
            menu.addItem(item)
        }
        if !projects.isEmpty {
            let heading = NSMenuItem(title: "Open Projects", action: nil, keyEquivalent: "")
            heading.isEnabled = false
            menu.addItem(heading)
            for path in projects.keys.sorted() {
                let branch = projects[path]?.git?.snapshot?.headDescription
                add((path as NSString).lastPathComponent + (branch.map { " · " + $0 } ?? ""), path: path)
            }
            menu.addItem(.separator())
        }

        let recent = composition.recentProjects.projects.filter { projects[$0.path] == nil }
        if !recent.isEmpty {
            let heading = NSMenuItem(title: "Recent Projects", action: nil, keyEquivalent: "")
            heading.isEnabled = false
            menu.addItem(heading)
            for entry in recent { add((entry.isPinned ? "★ " : "") + entry.name, path: entry.path) }
            menu.addItem(.separator())
        }

        let open = NSMenuItem(title: "Open Folder…", action: #selector(openFolder(_:)), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        let welcome = NSMenuItem(title: "Welcome", action: #selector(showWelcome(_:)), keyEquivalent: "")
        welcome.target = self
        menu.addItem(welcome)

        return menu
    }

    @objc private func openProjectFromMenu(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }

        Task { await openProjectFolder(path: path) }
    }

    private var activeProject: ProjectWorkspaceController? {
        projects.values.first { project in
            project.window === NSApp.keyWindow
        }
    }

    @objc func closeProject(_ sender: Any?) {
        guard let project = activeProject else { return }

        Task { await closeProject(project) }
    }

    func closeProject(_ project: ProjectWorkspaceController) async {
        let root = project.files.root
        guard closingProjects.insert(root).inserted else { return }

        defer { closingProjects.remove(root) }
        guard await unsavedChanges.canQuit(documents: { project.documents.map(\.session) }) else { return }

        project.closeProject()
    }

    /// File ▸ Close Opened Folders: files go back to the nearest package.
    @objc func closeOpenedFolders(_ sender: Any?) {
        // Keep the old command's meaning: release explicit roots without closing documents.
        for project in Array(projects.values) { project.releaseDocuments() }
        let contexts = composition.languageServices.contexts
        for folder in contexts.openedFolders { contexts.close(folder: folder) }
    }

    private func chooseFiles(startingAt folder: URL?) {
        let project = activeProject
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = folder
        guard panel.runModal() == .OK else { return }

        for url in panel.urls {
            Task { await open(path: url.path, in: project) }
        }
    }

    func open(
        path: String,
        revealing location: DefinitionLocation? = nil,
        in preferredProject: ProjectWorkspaceController? = nil
    ) async {
        do {
            let opened = try await composition.open(path: path)
            let targetIsOpen = preferredProject.map { projects[$0.files.root] === $0 } ?? true
            guard !isTerminating, targetIsOpen else {
                if opened.isNew { composition.close(opened.session) }

                return
            }

            if opened.isNew {
                let controller = composition.makeDocument(for: opened.session)
                if location != nil, Self.isSystemFile(path) { controller.openForReading() }
                let root = composition.languageServices.contexts.context(forFile: path)?.root
                show(controller, in: preferredProject ?? root.flatMap { projects[$0] })
            } else {
                if let document = documents.first(where: { $0.session === opened.session }) {
                    if let preferredProject, let host = standalone.removeValue(forKey: document.session.id) {
                        host.releaseDocument()
                        preferredProject.add(document)
                    }

                    document.showDocument()
                }

                welcome?.hide()
            }

            if let location {
                documents.first { $0.session === opened.session }?.reveal(
                    line: location.line,
                    character: location.character
                )
            }
        } catch is CancellationError {
            return
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Could not open “\((path as NSString).lastPathComponent)”"
            alert.informativeText = WorkspaceWindowController.describe(error)
            alert.runModal()
        }
    }

    // MARK: Recovery

    private func restoreUnsavedWork() async {
        let scan: RecoveryScan
        do {
            scan = try await composition.scanRecovery()
        } catch {
            NSLog("SwiftIDE: could not look for unsaved work: \(error)")

            return
        }
        for candidate in scan.candidates {
            guard askToRestore(candidate) else {
                try? await composition.discardRecovery(candidate)
                continue
            }

            do {
                let restored = try await composition.restore(candidate)
                switch restored.outcome {
                case .restored, .restoredAsScratch:
                    guard let session = restored.session else { break }

                    if restored.isNew {
                        show(composition.makeDocument(for: session))
                    } else {
                        documents.first { $0.session === session }?.showDocument()
                    }

                    // The old record goes only once the restored text is confirmed under its own;
                    // if that could not be written, the old one is the only copy there is.
                    try? await composition.retireRecovery(candidate, restoredAs: session) { [unowned self] in
                        await controller(for: session)?.flushRecovery()
                    }
                case .nothingToRestore:
                    try? await composition.discardRecovery(candidate)
                case .alreadyOpenAndModified:
                    break   // newer work is open; its own record replaces this one
                }
            } catch {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Could not restore “\(candidate.record.title)”"
                alert.informativeText = "\(WorkspaceWindowController.describe(error)) The saved copy was kept."
                alert.runModal()
            }
        }
        if !scan.unreadable.isEmpty {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = scan.unreadable.count == 1
                ? "A saved copy of unsaved work could not be read"
                : "\(scan.unreadable.count) saved copies of unsaved work could not be read"
            alert.informativeText = scan.unreadable.joined(separator: "\n")
            alert.runModal()
        }
    }

    /// Returns whether to restore.
    private func askToRestore(_ candidate: RecoveryCandidate) -> Bool {
        if let recoveryPrompt { return recoveryPrompt(candidate) }

        let record = candidate.record
        let when = record.savedAt.formatted(date: .abbreviated, time: .shortened)
        var lines = ["Unsaved changes were found from \(when)."]
        switch candidate.disk {
        case .changed:
            lines
                .append(
                    """
                    The file has been changed on disk since then. Restoring opens your text as unsaved changes; \
                    saving will ask before replacing the other changes.
                    """
                )
        case .missing:
            lines.append("The file no longer exists. It will open as an untitled document.")
        case .unreadable:
            lines.append("The file can no longer be read as text. It will open as an untitled document.")
        case .unchanged, .notApplicable:
            break
        }
        let alert = NSAlert()
        alert.messageText = "Restore unsaved changes to “\(record.title)”?"
        alert.informativeText = lines.joined(separator: "\n\n")
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Discard")

        return alert.runModal() == .alertFirstButtonReturn
    }

    private func controller(for session: DocumentSession) -> DocumentEditorController? {
        documents.first { $0.session === session }
    }

    /// Files that belong to the toolchain, an SDK or the system, which a jump to a definition can
    /// come to, and the interfaces the server generates: to read, not to change. A project that
    /// merely lives in /Applications or /opt is not one of them.
    static func isSystemFile(_ path: String) -> Bool {
        // The server writes the interface of a framework it was asked about into the temporary folder.
        if path.contains("/sourcekit-lsp/GeneratedInterfaces/") { return true }

        let markers = [
            ".sdk/",
            ".xctoolchain/",
            ".platform/Developer/",
            "/Contents/Developer/Platforms/",
            "/Library/Developer/CommandLineTools/",
            "/Library/Developer/Toolchains/",
        ]
        if markers.contains(where: path.contains) { return true }

        return ["/System/Library/", "/usr/include/", "/usr/lib/"].contains { path.hasPrefix($0) }
    }

    @objc func goBack(_ sender: Any?) {
        guard let place = history.pop() else { return }

        let project = activeProject
        Task {
            await open(
                path: place.path,
                revealing: DefinitionLocation(path: place.path, line: place.line, character: place.character),
                in: project
            )
        }
    }

    private func show(_ controller: DocumentEditorController, in project: ProjectWorkspaceController? = nil) {
        controller.onJumpFrom = { [weak self] place in self?.history.push(place) }
        controller.onOpenLocation = { [weak self, weak controller] location in
            guard let self else { return }

            let project = projects.values.first { $0.documents.contains { $0 === controller } }
            Task { await self.open(path: location.path, revealing: location, in: project) }
        }
        controller.onClose = { [weak self] closed in
            guard let self else { return }

            composition.close(closed.session)
            documents.removeAll { $0 === closed }
            if let host = standalone.removeValue(forKey: closed.session.id) { host.window?.close() }
            for project in projects.values where project.documents.contains(where: { $0 === closed }) {
                project.remove(closed)
            }
            returnToWelcomeIfNeeded()
        }
        controller.unsavedChanges = unsavedChanges
        documents.append(controller)
        gitCheckout.register(controller)
        welcome?.hide()
        if let project { project.add(controller) } else { hostStandalone(controller) }
    }

    private func hostStandalone(_ document: DocumentEditorController) {
        let host = WorkspaceWindowController(document: document)
        standalone[document.session.id] = host
        host.showDocument()
    }

    @objc func closeDocument(_ sender: Any?) {
        if let project = activeProject { project.closeDocument(sender) }
        else { NSApp.keyWindow?.performClose(sender) }
    }

}

extension AppDelegate: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(goBack(_:)) { return history.canGoBack }
        if item.action == #selector(closeOpenedFolders(_:)) {
            return !composition.languageServices.contexts.openedFolders.isEmpty
        }

        if item.action == #selector(closeProject(_:)) { return activeProject != nil }

        return true
    }
}
