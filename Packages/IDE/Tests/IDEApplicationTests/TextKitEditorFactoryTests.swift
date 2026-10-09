import AppKit
import EditorPlatformTextKit
import IDEApplication
import IDEDomain
import Testing

@Test @MainActor
func factoryBuildsTextKit2ViewOverBackendStorage() throws {
    let editor = TextKitEditorFactory.makeEditor(loadedText: "let x = 1\n")
    #expect(editor.textView.textLayoutManager != nil)
    #expect(editor.compatibility.isTextKit2)
    #expect(editor.backend.usesTextKit2)
    #expect(editor.textView.string == "let x = 1\n")
}

@Test @MainActor
func sessionEditsAreVisibleInTheNativeView() throws {
    let editor = TextKitEditorFactory.makeEditor(loadedText: "abc")
    let document = DocumentSession(path: "Main.swift", backend: editor.backend)
    try document.replaceText("let y = 2", expectedVersion: 0)
    #expect(editor.textView.string == "let y = 2")
    #expect(document.version == 1)
    #expect(editor.compatibility.isTextKit2)
}
