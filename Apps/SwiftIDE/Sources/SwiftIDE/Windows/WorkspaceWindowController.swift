import AppKit
import EditorPlatformTextKit
import EditorUI
import IDEApplication
import IDEDomain

@MainActor
final class WorkspaceWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    let session: DocumentSession
    private let editor: TextKitEditor
    private let isUntitled: Bool
    private let saveDocument: SaveDocumentUseCase
    private let reloadDocument: ReloadDocumentUseCase
    var onClose: ((WorkspaceWindowController) -> Void)?
    /// Decides whether unsaved edits allow this window to go away; shared with Quit.
    var unsavedChanges: UnsavedChangesCoordinator?

    init(
        document: DocumentSession, editor: TextKitEditor, isUntitled: Bool,
        saveDocument: SaveDocumentUseCase, reloadDocument: ReloadDocumentUseCase
    ) {
        self.session = document
        self.editor = editor
        self.isUntitled = isUntitled
        self.saveDocument = saveDocument
        self.reloadDocument = reloadDocument
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.contentView = EditorHostView(editor: editor)
        window.center()
        super.init(window: window)
        window.delegate = self
        // Surface an unexpected TextKit 1 fallback instead of silently degrading.
        editor.compatibility.onFallback = { [weak window] in
            window?.subtitle = "⚠︎ TextKit 1 fallback"
            NSLog("SwiftIDE: NSTextView fell back to TextKit 1")
        }
        window.subtitle = editor.compatibility.isTextKit2 ? "TextKit 2" : "⚠︎ TextKit 1"
        session.subscribeToChanges { [weak self] _ in self?.refreshTitle() }
        refreshTitle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func refreshTitle() {
        guard let window else { return }
        if isUntitled {
            window.title = "Untitled"
        } else {
            window.title = (session.path as NSString).lastPathComponent
            window.representedURL = URL(fileURLWithPath: session.path)
        }
        window.isDocumentEdited = session.isDirty
    }

    // MARK: Menu

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(saveDocument(_:)) { return !isUntitled }
        return true
    }

    @objc func saveDocument(_ sender: Any?) {
        Task { _ = await save() }
    }

    // MARK: Saving

    /// Returns whether a write succeeded; failures are shown to the user here. It does not say
    /// the document is clean: text typed during the write stays unsaved.
    func save() async -> Bool {
        do {
            _ = try await saveDocument.execute(document: session)
            refreshTitle()
            return true
        } catch FileStoreError.conflict {
            return await resolveConflict()
        } catch is CancellationError {
            return false
        } catch {
            present(error, doing: "save")
            return false
        }
    }

    /// The file changed on disk since it was read. Nothing was written; the user decides.
    private func resolveConflict() async -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "“\((session.path as NSString).lastPathComponent)” was changed on disk"
        alert.informativeText = "Saving now would replace changes made by another program."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Reload from Disk")
        alert.addButton(withTitle: "Overwrite")
        guard let window else { return false }
        switch await alert.beginSheetModal(for: window) {
        case .alertThirdButtonReturn:
            do {
                _ = try await saveDocument.execute(document: session, overwritingExternalChanges: true)
                refreshTitle()
                return true
            } catch {
                present(error, doing: "save")
                return false
            }
        case .alertSecondButtonReturn:
            do {
                try await reloadDocument.execute(document: session)
                refreshTitle()
            } catch {
                present(error, doing: "reload")
            }
            return false
        default:
            return false
        }
    }

    private func present(_ error: Error, doing action: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Could not \(action) “\((session.path as NSString).lastPathComponent)”"
        alert.informativeText = Self.describe(error)
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    static func describe(_ error: Error) -> String {
        switch error as? FileStoreError {
        case .notFound?: "The file or its folder no longer exists."
        case .permissionDenied?: "You do not have permission to change this file."
        case .notRegularFile?: "This is not a regular file."
        case .tooLarge(let size, let limit)?: "The file is \(size / 1_048_576) MB; the limit is \(limit / 1_048_576) MB."
        case .binary?: "The file contains binary data, not text."
        case .notUTF8?: "The file is not valid UTF-8. It was not opened, so it cannot be damaged."
        case .unsupportedEncoding?: "Only UTF-8 text is supported for now."
        case .changedWhileReading?: "The file changed while it was being read. Try again."
        case .cannotPreserveMetadata?: "The file’s permissions, owner, access list or extended attributes cannot be carried over to the saved copy, so nothing was written."
        case .io(let code)?: "System error \(code)."
        case .conflict?: "The file was changed on disk."
        case nil: error.localizedDescription
        }
    }

    // MARK: Closing

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard session.isDirty, let unsavedChanges else { return true }
        // Answered asynchronously: refuse now, close when the decision procedure allows it.
        Task {
            if await unsavedChanges.canClose(session) { window?.close() }
        }
        return false
    }

    /// The question shown for Close and for Quit. A scratch document cannot be saved yet.
    func promptForUnsavedChanges() async -> UnsavedChangesDecision {
        guard let window else { return .cancel }
        window.makeKeyAndOrderFront(nil)
        let alert = NSAlert()
        alert.messageText = "Do you want to save changes to “\(window.title)”?"
        alert.informativeText = "Your changes will be lost if you don’t save them."
        if isUntitled {
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Don’t Save")
            return await alert.beginSheetModal(for: window) == .alertSecondButtonReturn ? .discard : .cancel
        }
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don’t Save")
        switch await alert.beginSheetModal(for: window) {
        case .alertFirstButtonReturn: return .save
        case .alertThirdButtonReturn: return .discard
        default: return .cancel
        }
    }

    func windowWillClose(_ notification: Notification) {
        onClose?(self)
    }
}
