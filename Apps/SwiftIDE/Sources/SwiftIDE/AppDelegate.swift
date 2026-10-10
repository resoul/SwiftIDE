import AppKit
import IDEApplication
import IDEDomain

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let composition = AppCompositionRoot()
    private var windows: [WorkspaceWindowController] = []
    private var workspacePreview: WorkspacePreviewWindowController?
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
        MainMenu.install()
        NSApp.activate()
        if CommandLine.arguments.contains("--workspace-preview")
            || Bundle.main.bundleIdentifier == "org.swiftide.workspace-preview" {
            showWorkspacePreview(nil)

            return
        }

        Task {
            // Unsaved text from a run that did not end cleanly is offered back before anything else.
            await restoreUnsavedWork()
            if windows.isEmpty { newDocument(nil) }
        }
    }

    /// Leaving for the background is the moment a user may force-quit or lose power: the unsaved
    /// text is written now instead of waiting for the next pause in typing.
    func applicationDidResignActive(_ notification: Notification) {
        Task { [windows] in
            for window in windows { await window.flushRecovery() }
        }
    }

    /// AppKit does not consult windows when the app quits, so unsaved documents are checked here
    /// with the same procedure the windows use. Quitting waits for the answers.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard windows.contains(where: { $0.session.isDirty }) else { return .terminateNow }

        Task {
            // The windows are read again after every answer, not captured once.
            // The user's choice to lose changes must also remove their recovery copies, or they are
            // offered back at the next start. That takes time during which more can be typed, so it
            // is part of the decision: the procedure checks again afterwards, and nothing
            // suspends between its final check and this reply.
            let allowed = await unsavedChanges.canQuit(
                documents: { [unowned self] in windows.map(\.session) },
                release: { [unowned self] sessions in
                    for session in sessions { await controller(for: session)?.withdrawRecovery() }
                },
                reinstate: { [unowned self] sessions in
                    for session in sessions { controller(for: session)?.resumeRecovery() }
                }
            )
            NSApp.reply(toApplicationShouldTerminate: allowed)
        }

        return .terminateLater
    }

    /// Servers end when their pipes close, but not waiting for that keeps them from outliving us.
    func applicationWillTerminate(_ notification: Notification) {
        composition.languageServices.terminateAll()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    @objc func newDocument(_ sender: Any?) {
        show(composition.makeUntitledWindow())
    }

    @objc func showWorkspacePreview(_ sender: Any?) {
        if workspacePreview == nil { workspacePreview = WorkspacePreviewWindowController() }
        workspacePreview?.showWindow(nil)
        workspacePreview?.window?.makeKeyAndOrderFront(nil)
    }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }

        for url in panel.urls {
            Task { await open(path: url.path) }
        }
    }

    private func open(path: String, revealing location: DefinitionLocation? = nil) async {
        do {
            let opened = try await composition.open(path: path)
            if opened.isNew {
                let controller = composition.makeWindow(for: opened.session)
                if location != nil, Self.isSystemFile(path) { controller.openForReading() }
                show(controller)
            } else {
                windows.first { $0.session === opened.session }?.showWindow(nil)
            }

            if let location {
                windows.first { $0.session === opened.session }?.reveal(line: location.line, character: location.character)
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
                        show(composition.makeWindow(for: session))
                    } else {
                        windows.first { $0.session === session }?.showWindow(nil)
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
        let record = candidate.record
        let when = record.savedAt.formatted(date: .abbreviated, time: .shortened)
        var lines = ["Unsaved changes were found from \(when)."]
        switch candidate.disk {
        case .changed:
            lines.append("The file has been changed on disk since then. Restoring opens your text as unsaved changes; saving will ask before replacing the other changes.")
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

    private func controller(for session: DocumentSession) -> WorkspaceWindowController? {
        windows.first { $0.session === session }
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

        Task { await open(path: place.path, revealing: DefinitionLocation(path: place.path, line: place.line, character: place.character)) }
    }

    private func show(_ controller: WorkspaceWindowController) {
        controller.onJumpFrom = { [weak self] place in self?.history.push(place) }
        controller.onOpenLocation = { [weak self] location in
            guard let self else { return }

            Task { await self.open(path: location.path, revealing: location) }
        }
        controller.onClose = { [weak self] closed in
            guard let self else { return }

            composition.close(closed.session)
            windows.removeAll { $0 === closed }
        }
        controller.unsavedChanges = unsavedChanges
        windows.append(controller)
        controller.showWindow(nil)
    }

}

extension AppDelegate: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(goBack(_:)) { return history.canGoBack }

        return true
    }
}
