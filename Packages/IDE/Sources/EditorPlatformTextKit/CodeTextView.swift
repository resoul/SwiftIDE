import AppKit

final class CodeTextView: NSTextView {
    weak var bridge: NativeEditingBridge?
    var hooks: EditorInputHooks?

    override func keyDown(with event: NSEvent) {
        // Marked text belongs to the input method, whatever the key is.
        if let hooks, !hasMarkedText() {
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
            if modifiers == .control, event.charactersIgnoringModifiers == " ", let request = hooks.requestCompletion {
                return request()
            }

            if modifiers == [.control, .shift], event.charactersIgnoringModifiers == " ", let request = hooks.requestHover {
                return request()
            }

            hooks.interactionBegan?()

            if hooks.interceptKey?(event) == true { return }
        }

        super.keyDown(with: event)
    }

    // MARK: The pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self && area.userInfo?["code"] != nil { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: ["code": true]
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        hooks?.pointerMoved?(characterOffset(atViewPoint: convert(event.locationInWindow, from: nil)))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hooks?.pointerMoved?(nil)
    }

    override func mouseDown(with event: NSEvent) {
        if handleCommandClick(event) { return }

        super.mouseDown(with: event)
    }

    /// A click takes a description away; a Command-click on a character is the editor's if the
    /// application uses it. True if the click is used up. (The rest is the text view's own, which
    /// follows the pointer until the button is released.)
    func handleCommandClick(_ event: NSEvent) -> Bool {
        hooks?.interactionBegan?()
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers == .command, !hasMarkedText(),
              let offset = characterOffset(atViewPoint: convert(event.locationInWindow, from: nil)) else { return false }

        return hooks?.commandClick?(offset) == true
    }

    override func scrollWheel(with event: NSEvent) {
        hooks?.interactionBegan?()
        super.scrollWheel(with: event)
    }

    /// The system command behind Escape and F5. The default one offers words from a dictionary;
    /// here it is the editor's completion.
    override func complete(_ sender: Any?) {
        if let request = hooks?.requestCompletion { request() } else { super.complete(sender) }
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        guard let bridge else {
            super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)

            return
        }

        let isEmpty = (string as? NSAttributedString)?.length == 0 || (string as? String)?.isEmpty == true
        let wasComposing = bridge.beginMarkedTextUpdate(isEmpty: isEmpty)
        bridge.forcedOrigin = .composition
        bridge.performCoalesced {
            super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        }
        bridge.forcedOrigin = nil
        bridge.finishMarkedTextUpdate(wasComposing: wasComposing)
    }

    override func unmarkText() {
        guard let bridge else { return super.unmarkText() }

        bridge.performCoalesced(unmarking: markedRange()) { super.unmarkText() }
        bridge.syncComposition()
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        guard let bridge else { return super.insertText(string, replacementRange: replacementRange) }

        bridge.performCoalesced { super.insertText(string, replacementRange: replacementRange) }
        bridge.syncComposition()
    }
}
