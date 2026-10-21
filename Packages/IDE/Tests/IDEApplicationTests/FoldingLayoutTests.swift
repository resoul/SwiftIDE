import AppKit
import EditorPlatformTextKit
import Testing

@MainActor
private func laidOut(_ editor: TextKitEditor) -> (fragments: Int, height: CGFloat) {
    let manager = editor.textView.textLayoutManager!
    manager.ensureLayout(for: manager.documentRange)
    var count = 0
    manager.enumerateTextLayoutFragments(from: manager.documentRange.location, options: [.ensuresLayout]) { _ in
        count += 1

        return true
    }

    return (count, manager.usageBoundsForTextContainer.height)
}

@Test @MainActor
func foldedLinesLeaveTheLayoutButNotTheText() {
    let text = "func f() {\n    a\n    b\n    c\n}\nlet x = 1\n"
    let editor = TextKitEditorFactory.makeEditor(loadedText: text)
    editor.textView.frame = NSRect(x: 0, y: 0, width: 400, height: 400)
    let before = laidOut(editor)
    #expect(before.fragments == 6)
    // The body: the three lines between the header and the closing brace.
    let body = (text as NSString).range(of: "    a\n    b\n    c\n")
    editor.backend.setHiddenRanges([body])
    let after = laidOut(editor)
    #expect(after.fragments == 3 && after.height < before.height)
    #expect(editor.textView.string == text)
    editor.backend.setHiddenRanges([])
    #expect(laidOut(editor).fragments == 6)
}
