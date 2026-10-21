import AppKit
import EditorPlatformTextKit
import EditorUI
import IDEApplication
import Testing

@MainActor
private func editorWindow(_ text: String) -> (TextKitEditor, EditorHostView, NSWindow) {
    let editor = TextKitEditorFactory.makeEditor(loadedText: text)
    let session = DocumentSession(path: "Main.swift", backend: editor.backend)
    let host = EditorHostView(editor: editor, lineIndex: DocumentLineIndex(session: session, source: editor.backend))
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
    host.cacheDisplay(in: host.bounds, to: bitmap)

    return (editor, host, window)
}

private let sample = "a\tb\n    c  d\n\te\n"

@Test @MainActor
func nothingIsMarkedUntilTheSettingIsOn() {
    let (editor, _, _) = editorWindow(sample)
    #expect(editor.textView.whitespaceMarkFrames.isEmpty)
    editor.textView.setWhitespaceMarks(tabs: false, spaces: false)
    #expect(editor.textView.whitespaceMarkFrames.isEmpty)
}

@Test @MainActor
func tabsAreMarkedWithTheirOwnWidthAndSpacesOneByOne() {
    let (editor, _, _) = editorWindow(sample)
    editor.textView.setWhitespaceMarks(tabs: true, spaces: false)
    let tabs = editor.textView.whitespaceMarkFrames
    #expect(tabs.map(\.offset) == [1, 13] && tabs.allSatisfy(\.isTab))
    let first = tabs[0].frame
    #expect(first.width > 10, "a tab is as wide as the indent level")
    editor.textView.setWhitespaceMarks(tabs: false, spaces: true)
    let spaces = editor.textView.whitespaceMarkFrames
    #expect(spaces.map(\.offset) == [4, 5, 6, 7, 9, 10] && !spaces.contains { $0.isTab })
    let widths = Set(spaces.map { Int($0.frame.width * 100) })
    #expect(widths.count == 1, "every space has the cell of one character")
    editor.textView.setWhitespaceMarks(tabs: true, spaces: true)
    #expect(editor.textView.whitespaceMarkFrames.count == 8)
}

@Test @MainActor
func theMarksFollowTheTextAndNeverChangeIt() {
    let (editor, _, _) = editorWindow(sample)
    editor.textView.setWhitespaceMarks(tabs: true, spaces: true)
    let before = editor.textView.string
    _ = editor.textView.whitespaceMarkFrames
    #expect(editor.textView.string == before)
    editor.textView.insertText("\t", replacementRange: NSRange(location: 0, length: 0))
    #expect(editor.textView.whitespaceMarkFrames.map(\.offset).first == 0)
}

@Test @MainActor
func aFoldedBodyHasNoMarksAndTheViewportIsAllThatIsLookedAt() {
    let body = (0..<400).map { "\tline \($0)" }.joined(separator: "\n")
    let (editor, _, _) = editorWindow("func f() {\n\(body)\n}\n")
    editor.textView.setWhitespaceMarks(tabs: true, spaces: false)
    let marks = editor.textView.whitespaceMarkFrames
    #expect(!marks.isEmpty && marks.count < 100, "only the lines in view are looked up")
}
