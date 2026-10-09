import AppKit
import IDEApplication

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let composition = AppCompositionRoot()
    private var windows: [WorkspaceWindowController] = []
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
        newDocument(nil)
        NSApp.activate()
    }

    /// AppKit does not consult windows when the app quits, so unsaved documents are checked here
    /// with the same procedure the windows use. Quitting waits for the answers.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard windows.contains(where: { $0.session.isDirty }) else { return .terminateNow }
        Task {
            // The windows are read again after every answer, not captured once.
            let allowed = await unsavedChanges.canQuit(documents: { [unowned self] in windows.map(\.session) })
            NSApp.reply(toApplicationShouldTerminate: allowed)
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    @objc func newDocument(_ sender: Any?) {
        show(composition.makeUntitledWindow())
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

    private func open(path: String) async {
        do {
            let opened = try await composition.open(path: path)
            if opened.isNew {
                show(composition.makeWindow(for: opened.session))
            } else {
                windows.first { $0.session === opened.session }?.showWindow(nil)
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

    private func controller(for session: DocumentSession) -> WorkspaceWindowController? {
        windows.first { $0.session === session }
    }

    private func show(_ controller: WorkspaceWindowController) {
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
