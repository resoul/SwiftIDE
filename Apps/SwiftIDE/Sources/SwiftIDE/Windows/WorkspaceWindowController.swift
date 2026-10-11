import AppKit
import IDEApplication
import IDEDomain

/// A standalone host. Project documents use the same editor controller without an extra window.
@MainActor
final class WorkspaceWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    let editorController: DocumentEditorController
    var session: DocumentSession { editorController.session }
    var onClose: ((WorkspaceWindowController) -> Void)? {
        didSet { editorController.onClose = { [weak self] _ in if let self { onClose?(self) } } }
    }
    var unsavedChanges: UnsavedChangesCoordinator? {
        get { editorController.unsavedChanges }
        set { editorController.unsavedChanges = newValue }
    }

    init(document: DocumentEditorController) {
        self.editorController = document
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered,
                              defer: false)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.contentViewController = document
        window.center()
        super.init(window: window)
        window.delegate = self
        document.onActivate = { [weak window] in window?.makeKeyAndOrderFront(nil) }
        document.onPresentationChange = { [weak self] in self?.refreshPresentation() }
        document.bind(to: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func refreshPresentation() {
        window?.title = editorController.displayName
        window?.subtitle = editorController.status
        window?.representedURL = session.isUntitled ? nil : URL(fileURLWithPath: session.path)
        window?.isDocumentEdited = session.isDirty
    }

    /// Transfers the original editor to a project without closing its document or recovery journal.
    func releaseDocument() {
        editorController.deactivate()
        editorController.onActivate = nil
        editorController.onPresentationChange = nil
        window?.contentViewController = nil
        window?.delegate = nil
        window?.close()
    }

    func showDocument() { editorController.showDocument() }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard session.isDirty, let unsavedChanges else { return true }

        let editorController = editorController
        Task { [weak self] in
            if await unsavedChanges.canClose(editorController.session) { self?.window?.close() }
        }

        return false
    }
    func windowWillClose(_ notification: Notification) { editorController.close() }
    func validateMenuItem(_ item: NSMenuItem) -> Bool { editorController.validateMenuItem(item) }
    func save() async -> Bool { await editorController.save() }
    func saveAs(to url: URL, target: SaveAsTarget) async -> Bool { await editorController.saveAs(to: url, target: target) }
    func promptForUnsavedChanges() async -> UnsavedChangesDecision { await editorController.promptForUnsavedChanges() }
    func openForReading() { editorController.openForReading() }
    func reveal(line: Int, character: Int) { editorController.reveal(line: line, character: character) }
    static func describe(_ error: Error) -> String { DocumentEditorController.describe(error) }
    @objc func saveDocument(_ sender: Any?) { editorController.saveDocument(sender) }
    @objc func saveDocumentAs(_ sender: Any?) { editorController.saveDocumentAs(sender) }
    @objc func selectLanguage(_ sender: NSMenuItem) { editorController.selectLanguage(sender) }
    @objc func showQuickHelp(_ sender: Any?) { editorController.showQuickHelp(sender) }
    @objc func jumpToDefinition(_ sender: Any?) { editorController.jumpToDefinition(sender) }
    @objc func allowProjectConfiguration(_ sender: Any?) { editorController.allowProjectConfiguration(sender) }
    @objc func disallowProjectConfiguration(_ sender: Any?) { editorController.disallowProjectConfiguration(sender) }
    @objc func askAboutProjectConfigurationAgain(_ sender: Any?) { editorController.askAboutProjectConfigurationAgain(sender) }
}
