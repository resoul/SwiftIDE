import AppKit
import EditorPlatformTextKit
@testable import EditorUI
import IDEApplication
import IDEDomain
import IDETestSupport
import Testing

@MainActor
private final class ScriptedProvider: CompletionProviding {
    var items: [CompletionItem]
    var incomplete = false
    private(set) var carets: [Int] = []
    init(items: [CompletionItem]) { self.items = items }

    func completion(for session: DocumentSession, caret: @MainActor () -> Int) async -> CompletionOutcome {
        carets.append(caret())

        return .items(items, isIncomplete: incomplete)
    }
}

private func item(_ label: String, insert: String? = nil, filter: String? = nil, kind: CompletionKind = .method) -> CompletionItem {
    CompletionItem(label: label, detail: "T", insertText: insert ?? label, sortText: label, filterText: filter ?? label, kind: kind)
}

/// A real text view in a real window, a session over its storage, and the coordinator between them.
@MainActor
private struct Fixture {
    let editor: TextKitEditor
    let session: DocumentSession
    let window: NSWindow
    let provider: ScriptedProvider
    let coordinator: CompletionCoordinator
    var textView: NSTextView { editor.textView }

    init(_ text: String = "let s = \"a\"\ns") {
        editor = TextKitEditorFactory.makeEditor(loadedText: text)
        session = DocumentSession(path: "/w/Main.swift", backend: editor.backend)
        provider = ScriptedProvider(items: [
            item("append(contentsOf: String)", insert: "append(contentsOf: )", filter: "append(contentsOf:)"),
            item("count", kind: .property),
            item("uppercased()"),
        ])
        window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 600, height: 400), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let host = EditorHostView(editor: editor)
        window.contentView = host
        window.makeFirstResponder(editor.textView)
        coordinator = CompletionCoordinator(session: session, editor: editor, provider: provider)
        editor.textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
    }

    func type(_ string: String) {
        textView.insertText(string, replacementRange: textView.selectedRange())
        endEvent()
    }

    /// Lets the run loop close the undo manager's per-event group, as the end of a real event does.
    func endEvent() {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
    }

    func settle() async {
        for _ in 0..<40 { await Task.yield() }
    }

    func key(_ code: UInt16, characters: String = "", modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: code
        )!
    }

    var controller: CompletionController { coordinator.controller }
}

@Test @MainActor
func typingADotInARealTextViewShowsTheListAndTypingMoreKeepsIt() async throws {
    let f = Fixture()
    f.type(".")
    await f.settle()
    #expect(f.provider.carets == [14], "asked at the caret right after the dot")
    #expect(f.coordinator.popup.isVisible && f.controller.isShowing)

    f.type("a")
    await f.settle()
    #expect(f.controller.isActive, "the selection change of the keystroke did not end it")
    #expect(f.provider.carets.count == 1, "the list was complete: nothing asked again")
    f.type("p")
    f.type("p")
    await f.settle()
    #expect(f.controller.isShowing)
    #expect(f.session.text.hasSuffix("s.app"))
}

@Test @MainActor
func theArrowKeysAndReturnWorkOnAShowingListAndReturnIsANewlineOtherwise() async throws {
    let f = Fixture()
    // No list: none of these is the list's.
    for code: UInt16 in [36, 48, 125, 126, 53] {
        #expect(CompletionCoordinator.handle(f.key(code), controller: f.controller) == false, "key \(code) with no list")
    }
    f.type(".")
    await f.settle()
    #expect(CompletionCoordinator.handle(f.key(125), controller: f.controller), "Down")
    #expect(CompletionCoordinator.handle(f.key(126), controller: f.controller), "Up")
    #expect(CompletionCoordinator.handle(f.key(125, modifiers: .command), controller: f.controller) == false, "Command-Down is the editor's")
    #expect(CompletionCoordinator.handle(f.key(125, modifiers: .shift), controller: f.controller) == false, "Shift-Down extends a selection")
    #expect(CompletionCoordinator.handle(f.key(53), controller: f.controller), "Escape closes")
    #expect(!f.controller.isActive && !f.coordinator.popup.isVisible)
}

@Test @MainActor
func returnAcceptsTheSelectedRowAndPutsTheCaretInsideTheParentheses() async throws {
    let f = Fixture()
    f.type(".")
    await f.settle()
    f.type("app")
    #expect(CompletionCoordinator.handle(f.key(36, characters: "\r"), controller: f.controller))
    #expect(f.session.text == "let s = \"a\"\ns.append(contentsOf: )")
    #expect(f.textView.selectedRange() == NSRange(location: (f.session.text as NSString).length - 1, length: 0))
    #expect(!f.coordinator.popup.isVisible)
    #expect(f.textView.string == f.session.text)
}

@Test @MainActor
func acceptingIsOneUndoStep() async throws {
    let f = Fixture()
    f.type(".")
    await f.settle()
    f.type("cou")
    f.endEvent()
    #expect(CompletionCoordinator.handle(f.key(48, characters: "\t"), controller: f.controller))
    #expect(f.session.text.hasSuffix("s.count"))
    f.endEvent()
    f.editor.undo.undoManager.undo()
    #expect(f.session.text.hasSuffix("s.cou"), "back to what was typed, in one step: \(f.session.text.debugDescription)")
}

@Test @MainActor
func controlSpaceAndTheSystemCompleteCommandAskForCompletion() async throws {
    let f = Fixture(NSString(string: "s.cou") as String)
    f.textView.keyDown(with: f.key(49, characters: " ", modifiers: .control))
    await f.settle()
    #expect(f.provider.carets == [5], "Control-Space")
    f.controller.dismiss()

    f.textView.complete(nil)   // what Escape and F5 send
    await f.settle()
    #expect(f.provider.carets == [5, 5])
    #expect(f.coordinator.popup.isVisible)
}

@Test @MainActor
func aSpaceWithoutControlIsJustASpace() async throws {
    let f = Fixture(NSString(string: "s.cou") as String)
    f.textView.keyDown(with: f.key(49, characters: " "))
    await f.settle()
    #expect(f.provider.carets.isEmpty)
}

@Test @MainActor
func marked_textKeepsEveryKeyForTheInputMethod() async throws {
    let f = Fixture(NSString(string: "s.") as String)
    f.textView.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 2, length: 0))
    f.textView.keyDown(with: f.key(49, characters: " ", modifiers: .control))
    await f.settle()
    #expect(f.provider.carets.isEmpty, "not while the input method holds marked text")
    f.textView.unmarkText()
}

@Test @MainActor
func clickingARowChoosesItAndDoubleClickingAcceptsIt() async throws {
    let f = Fixture()
    f.type(".")
    await f.settle()
    f.coordinator.popup.onClick?(1, false)
    f.coordinator.popup.onClick?(1, true)
    #expect(f.session.text.hasSuffix("s.count"), "row 1 of the list in the server's order: append, count, uppercased")
}

@Test @MainActor
func movingTheCaretWithTheMouseClosesTheList() async throws {
    let f = Fixture()
    f.type(".")
    await f.settle()
    f.textView.setSelectedRange(NSRange(location: 2, length: 0))
    await f.settle()
    #expect(!f.controller.isActive && !f.coordinator.popup.isVisible)
}

@Test @MainActor
func thePopupSitsBelowTheCharacterAndAboveItWhenThereIsNoRoom() {
    let screen = NSRect(x: 0, y: 0, width: 1000, height: 800)
    let size = NSSize(width: 300, height: 200)
    let low = CompletionPopup.frame(size: size, below: NSRect(x: 100, y: 500, width: 8, height: 16), visibleScreen: screen)
    #expect(low.maxY < 500 && low.minX < 100, "under the line")
    let cramped = CompletionPopup.frame(size: size, below: NSRect(x: 100, y: 120, width: 8, height: 16), visibleScreen: screen)
    #expect(cramped.minY >= 136, "above the line when it would leave the screen")
    let right = CompletionPopup.frame(size: size, below: NSRect(x: 990, y: 500, width: 8, height: 16), visibleScreen: screen)
    #expect(right.maxX <= 1000, "inside the screen on the right")
}

@Test @MainActor
func theStatusLineShowsInTheSamePanelAndIsReplacedByTheList() async throws {
    let f = Fixture()
    f.coordinator.popup.showStatus(.notResponding, anchorOffset: 5)
    #expect(f.coordinator.popup.isVisible)
    #expect(!f.controller.isShowing, "a status line is not a list: Return stays a newline")
    #expect(CompletionCoordinator.handle(f.key(36), controller: f.controller) == false)

    f.type(".")
    await f.settle()
    #expect(f.coordinator.popup.isVisible && f.controller.isShowing, "the list takes the panel over")
    f.controller.dismiss()
    #expect(!f.coordinator.popup.isVisible)
}

@Test @MainActor
func everyStatusHasItsOwnText() {
    let all: [CompletionStatus] = [.waiting, .starting, .restarting, .notReady, .noSuggestions, .unavailable, .notResponding]
    let texts = all.map(CompletionPopup.text(for:))
    #expect(Set(texts).count == all.count && texts.allSatisfy { !$0.isEmpty })
}
