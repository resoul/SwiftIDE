import AppKit
import EditorPlatformTextKit
import EditorUI
import IDEApplication
import IDEDomain
import LanguageInfrastructure
import SyntaxInfrastructure
import UniformTypeIdentifiers

@MainActor
final class WorkspaceWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    let session: DocumentSession

    private let editor: TextKitEditor
    private let lineIndex: DocumentLineIndex
    private let registry: DocumentRegistry
    private let saveDocument: SaveDocumentUseCase
    private let reloadDocument: ReloadDocumentUseCase
    private let revisionOfFile: (String) -> FileRevision?
    private let colouring: SyntaxColouringController
    private let recovery: RecoveryCoordinator
    private let externalChanges: ExternalChangeMonitor
    private let container: EditorContainerView
    private let longLines: LongLineMonitor
    private let languageServices: LanguageServices
    private var readinessSubscription: UUID?
    private let languages: DocumentLanguages
    private let languageSelector: DocumentLanguageSelector
    private var completion: CompletionCoordinator?
    private var features: LanguageFeaturesCoordinator?
    private let host: EditorHostView
    private var isSystemFile = false
    private var isReadOnlyForLongLines = false

    var onClose: ((WorkspaceWindowController) -> Void)?
    /// A definition is in another file: the application opens it.
    var onOpenLocation: ((DefinitionLocation) -> Void)?
    /// A jump leaves this place: the application remembers it for Go Back.
    var onJumpFrom: ((NavigationPlace) -> Void)?
    var unsavedChanges: UnsavedChangesCoordinator?

    init(
        document: DocumentSession,
        editor: TextKitEditor,
        registry: DocumentRegistry,
        saveDocument: SaveDocumentUseCase,
        reloadDocument: ReloadDocumentUseCase,
        recovery: RecoveryCoordinator,
        externalChanges: ExternalChangeMonitor,
        revisionOfFile: @escaping (String) -> FileRevision?,
        makeHighlighter: @escaping (DocumentLanguage) -> (any SyntaxHighlighter)?,
        languages: DocumentLanguages,
        languageServices: LanguageServices
    ) {
        self.languageServices = languageServices
        self.languages = languages
        languageSelector = languages.selector(for: document)
        self.revisionOfFile = revisionOfFile
        self.session = document
        self.editor = editor
        self.lineIndex = DocumentLineIndex(session: document, source: editor.backend)
        self.registry = registry
        self.saveDocument = saveDocument
        self.reloadDocument = reloadDocument
        self.recovery = recovery
        self.externalChanges = externalChanges
        let textView = editor.textView
        colouring = SyntaxColouringController(
            session: document,
            source: editor.backend,
            policy: .standard,
            languages: languageSelector,
            supportedLanguages: TreeSitterHighlighter.supportedLanguages,
            makeHighlighter: makeHighlighter,
            present: { SyntaxPresenter(textView: textView, coordinator: $0, policy: .standard) }
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        host = EditorHostView(editor: editor, lineIndex: lineIndex)
        container = EditorContainerView(host: host)
        longLines = LongLineMonitor(lineIndex: lineIndex)
        window.contentView = container
        window.center()
        super.init(window: window)
        window.delegate = self

        editor.compatibility.onFallback = { [weak window] in
            window?.subtitle = "⚠︎ TextKit 1 fallback"
            NSLog("SwiftIDE: NSTextView fell back to TextKit 1")
        }
        colouring.onChange = { [weak self] _ in self?.refreshSubtitle() }
        languageSelector.subscribe { [weak self] _ in
            // Whatever was asked of the old language's server is not an answer for this one.
            self?.completion?.controller.dismiss()
            self?.features?.hover.dismiss()
            self?.refreshSubtitle()
        }
        recovery.onStatusChange = { [weak self] _ in self?.refreshSubtitle() }
        externalChanges.onChange = { [weak self] _ in self?.updateNotice() }
        refreshSubtitle()
        longLines.onChange = { [weak self] _ in self?.updateNotice() }
        updateNotice()
        session.subscribeToChanges { [weak self] _ in self?.refreshTitle() }
        refreshTitle()
        // Completion from the language server of the document's place; the server may still be
        // starting, in which case there is simply nothing to offer yet.
        completion = CompletionCoordinator(session: document, editor: editor, provider: languageServices)
        // Descriptions, definitions and problems from the same server.
        features = LanguageFeaturesCoordinator(
            session: document,
            editor: editor,
            host: host,
            lineIndex: lineIndex,
            provider: languageServices
        )
        features?.onDiagnosticsChange = { [weak self] in self?.refreshSubtitle() }
        features?.openLocation = { [weak self] location in self?.onOpenLocation?(location) }
        features?.willJump = { [weak self] offset in
            guard let self, let place = self.place(at: offset) else { return }

            self.onJumpFrom?(place)
        }
        // What the server is busy with (preparing the package, a decision awaited, fallback settings).
        readinessSubscription = languageServices.subscribeToReadiness(for: document) { [weak self] in self?.refreshSubtitle() }
        Task { [languageServices] in await languageServices.attach(document) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var displayName: String {
        session.isUntitled ? "Untitled" : (session.path as NSString).lastPathComponent
    }

    private func updateNotice() {
        let banner = container.banner
        if let notice = externalNotice() {
            banner.show(message: notice.message, buttons: notice.buttons)

            return
        }

        if isReadOnlyForLongLines {
            banner.show(
                message: "This window is read-only because of a very long line.",
                buttons: [.init(title: "Allow Editing") { [weak self] in self?.allowEditing() }]
            )

            return
        }

        guard longLines.state == .warning else { return banner.hide() }

        let length = longLines.longestLength.formatted()
        banner.show(
            message: "This file has a line of \(length) characters. Editing long lines can be slow, and syntax colours are off for them.",
            buttons: [
                .init(title: "Make Read-Only") { [weak self] in self?.makeReadOnly() },
                .init(title: "Keep Editing") { [weak self] in self?.longLines.dismiss() }
            ]
        )
    }

    private func externalNotice() -> (message: String, buttons: [NoticeBanner.Button])? {
        let dismiss = NoticeBanner.Button(title: "OK") { [weak self] in self?.externalChanges.dismiss() }
        switch externalChanges.state {
        case .none:
            return nil
        case .reloaded:
            return (
                "“\(displayName)” was changed on disk and reloaded.",
                [.init(title: "Undo") { [weak self] in
                    self?.editor.undo.undoManager.undo()
                    self?.externalChanges.dismiss()
                }, dismiss]
            )
        case .changedWhileEdited:
            return (
                "“\(displayName)” was changed on disk. This window has unsaved changes.",
                [.init(title: "Reload") { [weak self] in self?.reloadFromNotice() },
                 .init(title: "Keep Mine") { [weak self] in self?.externalChanges.keepMine() }]
            )
        case .removed:
            return (
                "“\(displayName)” was deleted or moved.",
                [.init(title: "Save As…") { [weak self] in
                    guard let self else { return }

                    Task { _ = await self.saveAs() }
                }, dismiss]
            )
        case .unreadable(let error):
            return ("“\(displayName)” was changed on disk, but it cannot be read as text. \(Self.describe(error))", [dismiss])
        }
    }

    private func reloadFromNotice() {
        Task {
            do {
                try await externalChanges.reload()
            } catch {
                present(error, doing: "reload")
            }
        }
    }

    private func makeReadOnly() {
        isReadOnlyForLongLines = true
        editor.textView.isEditable = false
        updateNotice()
        refreshSubtitle()
    }

    private func allowEditing() {
        isReadOnlyForLongLines = false
        editor.textView.isEditable = true
        longLines.dismiss()
        updateNotice()   // not a plain hide: a notice about the file may be showing
        refreshSubtitle()
    }

    /// The language the document is treated as, how sure that is, and what is missing for it.
    private var languageNote: String {
        let language = languageSelector.resolved

        return LanguageSupportNote.parts(
            for: language,
            hasColours: colouring.hasColours(for: language.language),
            hasLanguageFeatures: languageServices.serves(language.language)
        ).joined(separator: " · ")
    }

    /// Why a file of a coloured language has no colours, in words for the subtitle; nothing for
    /// a language that has none, which never had any.
    private var colourNote: String? {
        switch colouring.state {
        case .on, .off(.languageNotSupported): nil
        case .off(.tooLarge): "syntax colours off: large file"
        case .off(.unavailable): "syntax colours unavailable"
        }
    }

    /// Said only when unsaved text is not being kept, so the user knows a crash would lose it.
    private var recoveryNote: String? {
        switch recovery.status {
        case .protecting: nil
        case .tooLarge: "recovery off: large file"
        case .failing: "recovery failing"
        }
    }

    private func refreshSubtitle() {
        guard let window else { return }

        let engine = editor.compatibility.isTextKit2 ? "TextKit 2" : "⚠︎ TextKit 1"
        let readOnly = isReadOnlyForLongLines ? "read-only" : (isSystemFile ? "read-only (system file)" : nil)
        let readiness = languageServices.readiness(for: session)?.reason
        let temporary = session.isUntitled ? nil : TemporaryFolder.note(path: session.path, isCFamily: languageSelector.resolved.language.isCFamily)
        window.subtitle = [languageNote, readiness, temporary, features?.diagnostics.summary.text, engine, colourNote, recoveryNote, readOnly]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private func refreshTitle() {
        guard let window else { return }

        window.title = displayName
        window.representedURL = session.isUntitled ? nil : URL(fileURLWithPath: session.path)
        window.isDocumentEdited = session.isDirty
    }

    // MARK: Menu

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(selectLanguage(_:)) {
            let chosen = item.representedObject as? String
            item.state = chosen == languageSelector.override?.rawValue ? .on : .off
        }

        if item.action == #selector(allowProjectConfiguration(_:)) || item.action == #selector(disallowProjectConfiguration(_:))
            || item.action == #selector(askAboutProjectConfigurationAgain(_:)) {
            let decision = languageServices.trustDecision(for: session)
            if item.action == #selector(allowProjectConfiguration(_:)) { item.state = decision == .granted ? .on : .off }
            if item.action == #selector(disallowProjectConfiguration(_:)) { item.state = decision == .refused ? .on : .off }

            // Only a document of a project has a configuration to decide about; asking again needs a decision to forget.
            if item.action == #selector(askAboutProjectConfigurationAgain(_:)) { return decision != nil }

            return languageServices.isInProject(session)
        }

        return true
    }

    /// Edit ▸ Jump to Definition (⌃⌘J).
    @objc func jumpToDefinition(_ sender: Any?) {
        features?.jumpToDefinition()
    }

    /// Edit ▸ Quick Help (⌃⇧Space).
    @objc func showQuickHelp(_ sender: Any?) {
        features?.showQuickHelp()
    }

    /// A file of the toolchain or the system that a jump to a definition came to: to read, not to change.
    func openForReading() {
        isSystemFile = true
        editor.textView.isEditable = false
        refreshSubtitle()
    }

    /// A place in this document, for coming back to. Nil for a document with no file.
    private func place(at offset: Int) -> NavigationPlace? {
        guard !session.isUntitled else { return nil }

        let index = lineIndex.current
        let line = index.line(containing: offset)

        return NavigationPlace(path: session.path, line: line, character: offset - index.startOffset(ofLine: line))
    }

    /// Puts the caret at a place the language server named (zero-based line, UTF-16 offset in the line)
    /// and shows it.
    func reveal(line: Int, character: Int) {
        let index = lineIndex.current
        guard line >= 0, line < index.lineCount else { return }

        let start = index.startOffset(ofLine: line)
        let extent = index.lineExtent(line)
        let offset = start + min(max(0, character), extent.content)
        window?.makeKeyAndOrderFront(nil)
        editor.textView.setSelectedRange(NSRange(location: offset, length: 0))
        editor.textView.scrollRangeToVisible(NSRange(location: offset, length: 0))
        window?.makeFirstResponder(editor.textView)
    }

    /// Edit ▸ Language: the document's language, or back to deciding by name.
    /// Project ▸ Allow Project Configuration: the server's `.sourcekit-lsp/` and `.bsp/` may be used.
    @objc func allowProjectConfiguration(_ sender: Any?) {
        languageServices.setTrust(.granted, for: session)
    }

    @objc func disallowProjectConfiguration(_ sender: Any?) {
        languageServices.setTrust(.refused, for: session)
    }

    /// Forgets the decision: the question is asked again when the server next finds a configuration.
    @objc func askAboutProjectConfigurationAgain(_ sender: Any?) {
        languageServices.setTrust(nil, for: session)
    }

    @objc func selectLanguage(_ sender: NSMenuItem) {
        languageSelector.setOverride((sender.representedObject as? String).flatMap(DocumentLanguage.init(rawValue:)))
    }

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
                document: session,
                to: url.path,
                target: consent.target(for: url),
                registry: registry
            )
            refreshTitle()
            colouring.refresh()   // the name may have changed the kind of file

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
        if let document = error as? DocumentError, document == .pathChanged {
            return "The document was saved under another name meanwhile. Nothing was changed."
        }

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
        externalChanges.stop()
        completion?.controller.dismiss()
        features?.hover.dismiss()
        if let readinessSubscription { languageServices.unsubscribeFromReadiness(readinessSubscription) }
        languageServices.detach(session)
        languages.forget(session)
        // The window closes only for a clean document or one the user chose to discard: either way
        // nothing of it is to be recovered.
        Task { [recovery] in await recovery.discard() }
    }

    /// Writes the unsaved text now: for the moments the app may be lost, such as going to the background.
    /// Returns what is in the store afterwards (see `RecoveryCoordinator.flush()`).
    @discardableResult
    func flushRecovery() async -> Safekeeping? {
        await recovery.flush()
    }

    /// The user agreed to lose this document's unsaved changes (quit with Don't Save), but the quit
    /// is not final until the app has checked that nothing changed meanwhile.
    func withdrawRecovery() async {
        await recovery.withdraw()
    }

    /// The quit was refused: the unsaved text is protected again.
    func resumeRecovery() {
        recovery.resume()
    }
}
