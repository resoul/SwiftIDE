import AppKit
import EditorPlatformTextKit
import EditorUI
import IDEApplication
import IDEDomain
import UniformTypeIdentifiers

@MainActor
final class WorkspaceWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    let session: DocumentSession
    private let editor: TextKitEditor
    /// Line starts of the document, followed edit by edit; the margin draws from it.
    private let lineIndex: DocumentLineIndex
    private let registry: DocumentRegistry
    private let saveDocument: SaveDocumentUseCase
    private let reloadDocument: ReloadDocumentUseCase
    private let revisionOfFile: (String) -> FileRevision?
    /// Syntax colours of the document, when it has any: the coordinator keeps them, the presenter
    /// draws them. Both live as long as the window.
    private var syntax: (coordinator: SyntaxCoordinator, presenter: SyntaxPresenter)?
    private var colourNote: String?
    var onClose: ((WorkspaceWindowController) -> Void)?
    /// Decides whether unsaved edits allow this window to go away; shared with Quit.
    var unsavedChanges: UnsavedChangesCoordinator?

    init(
        document: DocumentSession, editor: TextKitEditor, registry: DocumentRegistry,
        saveDocument: SaveDocumentUseCase, reloadDocument: ReloadDocumentUseCase,
        revisionOfFile: @escaping (String) -> FileRevision?,
        makeHighlighter: () -> (any SyntaxHighlighter)?
    ) {
        self.revisionOfFile = revisionOfFile
        self.session = document
        self.editor = editor
        self.lineIndex = DocumentLineIndex(session: document, source: editor.backend)
        self.registry = registry
        self.saveDocument = saveDocument
        self.reloadDocument = reloadDocument
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.contentView = EditorHostView(editor: editor, lineIndex: lineIndex)
        window.center()
        super.init(window: window)
        window.delegate = self
        // Surface an unexpected TextKit 1 fallback instead of silently degrading.
        editor.compatibility.onFallback = { [weak window] in
            window?.subtitle = "⚠︎ TextKit 1 fallback"
            NSLog("SwiftIDE: NSTextView fell back to TextKit 1")
        }
        startColouring(makeHighlighter)
        refreshSubtitle()
        session.subscribeToChanges { [weak self] _ in self?.refreshTitle() }
        refreshTitle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var displayName: String {
        session.isUntitled ? "Untitled" : (session.path as NSString).lastPathComponent
    }

    /// Swift sources get syntax colours, up to a size; a larger file is shown plain, and the
    /// window says so instead of silently dropping the colours.
    private func startColouring(_ makeHighlighter: () -> (any SyntaxHighlighter)?) {
        guard session.path.hasSuffix(".swift") else { return }
        let policy = SyntaxPolicy.standard
        guard policy.allowsColouring(documentLength: session.utf16Length) else {
            colourNote = "syntax colours off: large file"
            return
        }
        guard let highlighter = makeHighlighter() else { return }
        let coordinator = SyntaxCoordinator(session: session, source: editor.backend, highlighter: highlighter)
        syntax = (coordinator, SyntaxPresenter(textView: editor.textView, coordinator: coordinator, policy: policy))
    }

    private func refreshSubtitle() {
        guard let window else { return }
        let engine = editor.compatibility.isTextKit2 ? "TextKit 2" : "⚠︎ TextKit 1"
        window.subtitle = [engine, colourNote].compactMap { $0 }.joined(separator: " · ")
    }

    private func refreshTitle() {
        guard let window else { return }
        window.title = displayName
        window.representedURL = session.isUntitled ? nil : URL(fileURLWithPath: session.path)
        window.isDocumentEdited = session.isDirty
    }

    // MARK: Menu

    func validateMenuItem(_ item: NSMenuItem) -> Bool { true }

    @objc func saveDocument(_ sender: Any?) {
        Task { _ = await save() }
    }

    @objc func saveDocumentAs(_ sender: Any?) {
        Task { _ = await saveAs() }
    }

    // MARK: Saving

    /// Returns whether a write succeeded; failures are shown to the user here. It does not say
    /// the document is clean: text typed during the write stays unsaved. A document without a
    /// file asks for a name first.
    func save() async -> Bool {
        if session.isUntitled { return await saveAs() }
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

    /// Asks for a name and saves the document there; from then on the document is that file.
    func saveAs() async -> Bool {
        guard let window else { return false }
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.swiftSource]
        panel.allowsOtherFileTypes = true
        panel.nameFieldStringValue = session.isUntitled ? "Untitled.swift" : displayName
        if !session.isUntitled {
            panel.directoryURL = URL(fileURLWithPath: session.path).deletingLastPathComponent()
        }
        let consent = SavePanelConsent(revisionOfFile: revisionOfFile)
        panel.delegate = consent
        guard await panel.beginSheetModal(for: window) == .OK, let url = panel.url else { return false }

        // The panel asks before replacing a file; what it was agreed to is that file, as it was.
        do {
            _ = try await saveDocument.saveAs(
                document: session, to: url.path, target: consent.target(for: url), registry: registry
            )
            refreshTitle()
            return true
        } catch is CancellationError {
            return false
        } catch {
            present(error, doing: "save", fileName: url.lastPathComponent)
            return false
        }
    }

    /// The file changed on disk since it was read. Nothing was written; the user decides.
    private func resolveConflict() async -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "“\(displayName)” was changed on disk"
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

    private func present(_ error: Error, doing action: String, fileName: String? = nil) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Could not \(action) “\(fileName ?? displayName)”"
        alert.informativeText = Self.describe(error)
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    static func describe(_ error: Error) -> String {
        if error is OpenDocumentError {
            return "That file is being saved by another window right now. Try again in a moment."
        }
        if let save = error as? SaveError {
            switch save {
            case .targetOpenElsewhere: return "That file is already open in another window. Close it or choose another name."
            case .targetBeingSaved: return "Another document is being saved under that name right now. Choose another name."
            case .saveInProgress: return "A save of this document is already in progress."
            case .untitled: return "This document has no file yet. Choose a name first."
            }
        }
        switch error as? FileStoreError {
        case .notFound?: return "The file or its folder no longer exists."
        case .permissionDenied?: return "You do not have permission to change this file."
        case .notRegularFile?: return "This is not a regular file."
        case .tooLarge(let size, let limit)?: return "The file is \(size / 1_048_576) MB; the limit is \(limit / 1_048_576) MB."
        case .binary?: return "The file contains binary data, not text."
        case .notUTF8?: return "The file is not valid UTF-8. It was not opened, so it cannot be damaged."
        case .unsupportedEncoding?: return "Only UTF-8 text is supported for now."
        case .changedWhileReading?: return "The file changed while it was being read. Try again."
        case .cannotPreserveMetadata?: return "The file’s permissions, owner, access list or extended attributes cannot be carried over to the saved copy, so nothing was written."
        case .io(let code)?: return "System error \(code)."
        case .conflict?: return "A file with this name appeared after you chose it, or the file was changed on disk. Nothing was written."
        case nil: return error.localizedDescription
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

    /// The question shown for Close and for Quit. Saving a document without a file asks for a
    /// name first; if that is cancelled the document stays open.
    func promptForUnsavedChanges() async -> UnsavedChangesDecision {
        guard let window else { return .cancel }
        window.makeKeyAndOrderFront(nil)
        let alert = NSAlert()
        alert.messageText = "Do you want to save changes to “\(displayName)”?"
        alert.informativeText = "Your changes will be lost if you don’t save them."
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
