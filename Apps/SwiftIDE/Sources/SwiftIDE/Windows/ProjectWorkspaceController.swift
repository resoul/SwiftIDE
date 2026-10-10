import AppKit
import IDEApplication
import WorkspaceUI

/// An explicitly opened folder. Documents keep their existing controllers as native AppKit tabs.
@MainActor
final class ProjectWorkspaceController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    let files: ProjectFiles
    let layout: WorkspaceLayoutState
    private(set) var documents: [WorkspaceWindowController] = []
    var openFile: ((String) -> Void)?
    var onClose: (() -> Void)?
    private var closing = false
    private let browser: ProjectFilesContainer

    init(files: ProjectFiles, layout: WorkspaceLayoutState = .init()) {
        self.files = files
        self.layout = layout
        let empty = NSTextField(wrappingLabelWithString: "Open a file from Files to begin editing.\nDouble-click a file, or select it and press Return.")
        empty.alignment = .center
        empty.textColor = .secondaryLabelColor
        let editor = NSView()
        empty.translatesAutoresizingMaskIntoConstraints = false
        editor.addSubview(empty)
        NSLayoutConstraint.activate([
            empty.centerXAnchor.constraint(equalTo: editor.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: editor.centerYAnchor),
            empty.widthAnchor.constraint(lessThanOrEqualTo: editor.widthAnchor, constant: -40)
        ])
        browser = ProjectFilesContainer(model: files, editor: editor, layout: layout)
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
        browser.files.openFile = { [weak self] in self?.openFile?($0) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func add(_ document: WorkspaceWindowController) {
        guard !documents.contains(where: { $0 === document }), let newWindow = document.window else { return }

        let previous = documents.last?.window
        newWindow.tabGroup?.removeWindow(newWindow)
        document.installFiles(files, layout: layout) { [weak self] in self?.openFile?($0) }
        ProjectDocumentTabs.configure(newWindow, root: files.root)
        if let previous {
            ProjectDocumentTabs.append(newWindow, to: previous)
        } else if let window {
            newWindow.setFrame(window.frame, display: false)
            window.orderOut(nil)
        }

        documents.append(document)
        document.onPresentationChange = { [weak self] in self?.updateUnsavedPaths() }
        document.onFileSaved = { [weak self] in self?.files.refresh() }
        updateUnsavedPaths()
        document.showDocument()
    }

    func remove(_ document: WorkspaceWindowController) {
        documents.removeAll { $0 === document }
        document.onPresentationChange = nil
        document.onFileSaved = nil
        updateUnsavedPaths()
        if documents.isEmpty, !closing { showWorkspace() }
    }

    func showWorkspace() {
        if let document = documents.first { document.showDocument() } else {
            showWindow(nil)
            window?.makeKeyAndOrderFront(nil)
        }
    }

    func releaseDocuments() {
        closing = true
        for document in documents {
            document.onPresentationChange = nil
            document.onFileSaved = nil
            document.removeFiles()
            document.showDocument()
        }
        documents.removeAll()
        window?.close()
    }

    private func updateUnsavedPaths() {
        let paths = Set(documents.filter { $0.session.isDirty && !$0.session.isUntitled }.map { $0.session.path })
        if files.unsavedPaths != paths { files.unsavedPaths = paths }
    }

    /// Called only after shared reconciliation approves every current document, without another await.
    func closeProject() {
        closing = true
        for document in Array(documents) { document.window?.close() }
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        files.stop()
        browser.disconnect()
        onClose?()
    }

    @objc func showPreviewFiles(_ sender: Any?) { browser.shell.select(.files) }
    @objc func toggleFocusEditor(_ sender: Any?) { browser.shell.toggleFocusEditor(sender) }
    @objc func resetWorkspaceLayout(_ sender: Any?) { browser.shell.resetWorkspaceLayout(sender) }
    @objc func showPreviewSearch(_ sender: Any?) {}
    @objc func showPreviewSourceControl(_ sender: Any?) {}
    @objc func showPreviewTerminal(_ sender: Any?) {}
    @objc func showPreviewAssistant(_ sender: Any?) {}
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        ![ #selector(showPreviewSearch(_:)), #selector(showPreviewSourceControl(_:)), #selector(showPreviewTerminal(_:)), #selector(showPreviewAssistant(_:)) ].contains(item.action)
    }
}
