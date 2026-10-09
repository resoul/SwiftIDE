import IDEInfrastructure

@main
struct ArchitectureDemo {
    @MainActor
    static func main() async throws {
        let path = "Demo.swift"
        let original = "let message = \"Hello\"\n"
        let root = AppCompositionRoot(store: MemoryDocumentFileStore(contents: [path: original]))
        let editor = root.makeEditor(path: path, loadedText: original)

        try editor.replaceText("let message = \"Привет, Swift IDE\"\n")
        print("After edit: dirty = \(editor.isDirty)")
        let receipt = try await editor.save()
        print("Saved version: \(receipt.savedVersion); current = \(receipt.isCurrent)")
        print("After save: dirty = \(editor.isDirty)")
        let stored = await root.store.text(at: path)
        print("In-memory file: \(stored ?? "<missing>")", terminator: "")
    }
}
