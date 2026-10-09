import EditorPlatformTextKit
import IDEApplication

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

    /// Loading from disk arrives with the real DocumentFileStore; this window is untitled.
    func makeWorkspaceWindow() -> WorkspaceWindowController {
        let editor = TextKitEditorFactory.makeEditor(loadedText: Self.sampleText)
        let document = DocumentSession(path: "Untitled.swift", backend: editor.backend)
        return WorkspaceWindowController(document: document, editor: editor)
    }
}
