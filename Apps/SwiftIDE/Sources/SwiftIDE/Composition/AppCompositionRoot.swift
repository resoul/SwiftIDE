import EditorPlatformTextKit
import FileSystemInfrastructure
import IDEApplication
import IDEDomain

/// Only the composition layer constructs concrete adapters.
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
    private let registry = DocumentRegistry()
    /// Editors built while opening, until their window takes them over.
    private var pendingEditors: [DocumentID: TextKitEditor] = [:]

    private(set) lazy var saveDocument = SaveDocumentUseCase(store: store)
    private(set) lazy var reloadDocument = ReloadDocumentUseCase(store: store)
    private lazy var openDocument = OpenDocumentUseCase(store: store, registry: registry) { [unowned self] file in
        let editor = TextKitEditorFactory.makeEditor(loadedText: file.text)
        let session = DocumentSession(loaded: file, backend: editor.backend)
        pendingEditors[session.id] = editor
        return session
    }

    /// A scratch window without a file. Save As gives it one and registers it.
    func makeUntitledWindow() -> WorkspaceWindowController {
        let editor = TextKitEditorFactory.makeEditor(loadedText: Self.sampleText)
        let session = DocumentSession(path: "Untitled.swift", backend: editor.backend, isUntitled: true)
        return WorkspaceWindowController(
            document: session, editor: editor, registry: registry,
            saveDocument: saveDocument, reloadDocument: reloadDocument,
            revisionOfFile: Self.revisionOfFile
        )
    }

    /// Opens a file, or returns the window of the one that is already open.
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
            revisionOfFile: Self.revisionOfFile
        )
    }

    /// The state of an existing file, for the moment a user agrees to replace it.
    private static let revisionOfFile: (String) -> FileRevision? = { path in
        (try? AtomicDocumentFileStore.currentRevision(atPath: path)) ?? nil
    }

    func close(_ session: DocumentSession) {
        registry.remove(session)
    }
}
