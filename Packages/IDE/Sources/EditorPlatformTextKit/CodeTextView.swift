import AppKit

final class CodeTextView: NSTextView {
    weak var bridge: NativeEditingBridge?

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
