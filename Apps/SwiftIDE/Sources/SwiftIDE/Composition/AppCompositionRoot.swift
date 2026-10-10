import EditorPlatformTextKit
import FileSystemInfrastructure
import Foundation
import IDEApplication
import IDEDomain
import LanguageInfrastructure
import SyntaxInfrastructure

@MainActor
final class AppCompositionRoot {
    private static let sampleText = """
    import Foundation

    struct Greeter {
        let name: String

        func greet() -> String {
            "Hello, \\(name)! 👋"
        }
    }

    print(Greeter(name: "Swift IDE").greet())

    """

    private let store = AtomicDocumentFileStore()
    private let recoveryStore: any RecoveryStore = RecoveryJournal(directory: AppCompositionRoot.recoveryDirectory)
    private let registry = DocumentRegistry()
    private let fileWatcher: any FileWatching = VnodeFileWatcher()
    private var pendingEditors: [DocumentID: TextKitEditor] = [:]

    let languages = DocumentLanguages(store: UserDefaultsLanguageOverrideStore())
    lazy var languageServices = LanguageServices(scratchRoot: AppCompositionRoot.languageScratchDirectory, languages: languages)

    private(set) lazy var saveDocument = SaveDocumentUseCase(store: store)
    private(set) lazy var reloadDocument = ReloadDocumentUseCase(store: store)
    private lazy var openDocument = OpenDocumentUseCase(store: store, registry: registry) { [unowned self] file in
        let editor = TextKitEditorFactory.makeEditor(loadedText: file.text)
        let session = DocumentSession(loaded: file, backend: editor.backend)
        pendingEditors[session.id] = editor
        return session
    }

    private static var languageScratchDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("SwiftIDE", isDirectory: true).appendingPathComponent("LanguageScratch", isDirectory: true)
    }

    private static var recoveryDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("SwiftIDE", isDirectory: true).appendingPathComponent("Recovery", isDirectory: true)
    }

    private lazy var restorer = RecoveryRestorer(store: recoveryStore, files: store, open: openDocument) { [unowned self] _ in
        let editor = TextKitEditorFactory.makeEditor(loadedText: "")
        let session = DocumentSession(path: "Untitled.swift", backend: editor.backend, isUntitled: true)
        pendingEditors[session.id] = editor
        return session
    }

    func scanRecovery() async throws -> RecoveryScan {
        try await restorer.scan()
    }

    func restore(_ candidate: RecoveryCandidate) async throws -> RestoredDocument {
        try await restorer.restore(candidate)
    }

    func discardRecovery(_ candidate: RecoveryCandidate, unlessKept key: RecoveryKey? = nil) async throws {
        try await restorer.discard(candidate, unlessKept: key)
    }

    func retireRecovery(
        _ candidate: RecoveryCandidate, restoredAs session: DocumentSession,
        afterKeeping keep: @MainActor () async -> Safekeeping?
    ) async throws {
        try await restorer.retire(candidate, restoredAs: session, afterKeeping: keep)
    }

    func makeUntitledWindow() -> WorkspaceWindowController {
        let editor = TextKitEditorFactory.makeEditor(loadedText: Self.sampleText)
        let session = DocumentSession(path: "Untitled.swift", backend: editor.backend, isUntitled: true)
        return WorkspaceWindowController(
            document: session, editor: editor, registry: registry,
            saveDocument: saveDocument, reloadDocument: reloadDocument,
            recovery: RecoveryCoordinator(session: session, store: recoveryStore),
            externalChanges: makeExternalChangeMonitor(for: session),
            revisionOfFile: Self.revisionOfFile, makeHighlighter: Self.makeHighlighter,
            languages: languages, languageServices: languageServices
        )
    }

    private func makeExternalChangeMonitor(for session: DocumentSession) -> ExternalChangeMonitor {
        ExternalChangeMonitor(session: session, files: store, watcher: fileWatcher, reload: reloadDocument)
    }

    func open(path: String) async throws -> OpenedDocument {
        try await openDocument.execute(path: path)
    }

    func makeWindow(for session: DocumentSession) -> WorkspaceWindowController {
        guard let editor = pendingEditors.removeValue(forKey: session.id) else {
            preconditionFailure("A new document must come with its editor")
        }
        return WorkspaceWindowController(
            document: session, editor: editor, registry: registry,
            saveDocument: saveDocument, reloadDocument: reloadDocument,
            recovery: RecoveryCoordinator(session: session, store: recoveryStore),
            externalChanges: makeExternalChangeMonitor(for: session),
            revisionOfFile: Self.revisionOfFile, makeHighlighter: Self.makeHighlighter,
            languages: languages, languageServices: languageServices
        )
    }

    private static let makeHighlighter: (DocumentLanguage) -> (any SyntaxHighlighter)? = { language in
        try? TreeSitterHighlighter(language: language)
    }

    private static let revisionOfFile: (String) -> FileRevision? = { path in
        (try? AtomicDocumentFileStore.currentRevision(atPath: path)) ?? nil
    }

    func close(_ session: DocumentSession) {
        registry.remove(session)
    }
}
