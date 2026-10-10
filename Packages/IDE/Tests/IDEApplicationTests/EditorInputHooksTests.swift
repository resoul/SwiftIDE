import AppKit
import EditorPlatformTextKit
import Testing

@MainActor
private func keyEvent(_ characters: String, modifiers: NSEvent.ModifierFlags = [], keyCode: UInt16 = 0) throws -> NSEvent {
    try #require(NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: modifiers,
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        characters: characters,
        charactersIgnoringModifiers: characters,
        isARepeat: false,
        keyCode: keyCode
    ))
}

@Test @MainActor
func aKeyGoesToTheHooksBeforeTheTextViewAndIsNotTypedWhenTheyUseIt() throws {
    let editor = TextKitEditorFactory.makeEditor(loadedText: "")
    var seen: [String] = []
    editor.input.interceptKey = { event in seen.append(event.characters ?? ""); return true }
    editor.textView.keyDown(with: try keyEvent("a"))
    #expect(seen == ["a"])
    #expect(editor.textView.string.isEmpty, "a key the hooks used is not inserted")
}

@Test @MainActor
func aKeyTheHooksDoNotUseIsHandledByTheTextViewAsUsual() throws {
    let editor = TextKitEditorFactory.makeEditor(loadedText: "")
    editor.input.interceptKey = { _ in false }
    editor.textView.keyDown(with: try keyEvent("a"))
    #expect(editor.textView.string == "a")
}

@Test @MainActor
func controlSpaceAsksForCompletionAndPlainSpaceDoesNot() throws {
    let editor = TextKitEditorFactory.makeEditor(loadedText: "")
    var asked = 0
    editor.input.requestCompletion = { asked += 1 }
    editor.textView.keyDown(with: try keyEvent(" ", modifiers: .control))
    #expect(asked == 1)
    #expect(editor.textView.string.isEmpty)
    editor.textView.keyDown(with: try keyEvent(" "))
    #expect(asked == 1)
    #expect(editor.textView.string == " ")
}

@Test @MainActor
func whileAnInputMethodHoldsMarkedTextNoKeyGoesToTheHooks() throws {
    let editor = TextKitEditorFactory.makeEditor(loadedText: "")
    var intercepted = 0, asked = 0
    editor.input.interceptKey = { _ in intercepted += 1; return true }
    editor.input.requestCompletion = { asked += 1 }
    editor.textView.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
    try #require(editor.textView.hasMarkedText())
    editor.textView.keyDown(with: try keyEvent("\r", keyCode: 36))
    #expect(intercepted == 0 && asked == 0, "Return belongs to the input method")
    // Return committed the text; compose again for the next key.
    editor.textView.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
    try #require(editor.textView.hasMarkedText())
    editor.textView.keyDown(with: try keyEvent(" ", modifiers: .control))
    #expect(intercepted == 0 && asked == 0, "Control-Space belongs to the input method")
}

@Test @MainActor
func theSystemCompleteCommandIsTheEditorsCompletionWhenHooked() {
    let editor = TextKitEditorFactory.makeEditor(loadedText: "")
    var asked = 0
    editor.input.requestCompletion = { asked += 1 }
    editor.textView.complete(nil)
    #expect(asked == 1)
}
