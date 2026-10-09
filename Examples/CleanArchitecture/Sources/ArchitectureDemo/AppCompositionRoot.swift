import IDEApplication
import IDEInfrastructure
import IDEPresentation
import EditorPlatformTextKit

/// Only the composition layer constructs concrete adapters.
@MainActor
final class AppCompositionRoot {
    let store: MemoryDocumentFileStore
    private let saveDocument: SaveDocumentUseCase

    init(store: MemoryDocumentFileStore) {
        self.store = store
        self.saveDocument = SaveDocumentUseCase(store: store)
    }

    /// Called with content loaded by an opening scenario; loading is outside this demo.
    func makeEditor(path: String, loadedText: String) -> EditorController {
        let backend = TextKitDocumentBackend(loadedText: loadedText)
        let document = DocumentSession(path: path, backend: backend)
        return EditorController(document: document, saveDocument: saveDocument)
    }
}
