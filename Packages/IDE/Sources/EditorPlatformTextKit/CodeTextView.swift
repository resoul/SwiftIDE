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
            if hooks.interceptKey?(event) == true { return }
        }
        super.keyDown(with: event)
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
