import AppKit
import EditorPlatformTextKit
import IDEApplication
import IDEDomain

/// Completion in one editor window: the controller, the list, and the keys and notifications of
/// the text view that connect them.
@MainActor
public final class CompletionCoordinator {
    public let controller: CompletionController
    public let popup: CompletionPopup
    private var selectionObserver: NSObjectProtocol?
    private let textView: NSTextView
    private let input: EditorInputHooks

    public init(session: DocumentSession, editor: TextKitEditor, provider: any CompletionProviding) {
        textView = editor.textView
        input = editor.input
        let textView = editor.textView
        let source = editor.backend
        popup = CompletionPopup(textView: textView)
        controller = CompletionController(
            session: session, provider: provider,
            environment: CompletionEnvironment(
                caret: { [weak textView] in
                    guard let range = textView?.selectedRange(), range.length == 0, range.location != NSNotFound else { return nil }
                    return range.location
                },
                text: { source.substring(in: $0) },
                setCaret: { [weak textView] in textView?.setSelectedRange(NSRange(location: $0, length: 0)) }
            ),
            presenter: popup
        )
        let controller = controller
        popup.onClick = { row, isDouble in
            controller.select(row: row)
            if isDouble { controller.accept() }
        }
        popup.onClose = { controller.dismiss() }
        input.requestCompletion = { controller.requestManually() }
        input.interceptKey = { Self.handle($0, controller: controller) }
        selectionObserver = NotificationCenter.default.addObserver(
            forName: NSTextView.didChangeSelectionNotification, object: textView, queue: .main
        ) { _ in MainActor.assumeIsolated { controller.selectionDidChange() } }
    }

    isolated deinit {
        if let selectionObserver { NotificationCenter.default.removeObserver(selectionObserver) }
        input.interceptKey = nil
        input.requestCompletion = nil
        controller.dismiss()
    }

    /// The keys a showing list uses. Without a list they are the editor's: Return is a newline,
    /// Tab is a tab, the arrows move the caret.
    static func handle(_ event: NSEvent, controller: CompletionController) -> Bool {
        guard event.type == .keyDown else { return false }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        guard modifiers.isEmpty else { return false }
        switch event.keyCode {
        case 53 where controller.isActive:        // Escape ends a request still out, too
            controller.dismiss()
            return true
        case 36, 76, 48:                          // Return, Enter, Tab
            return controller.isShowing && controller.accept()
        case 126 where controller.isShowing:      // Up
            controller.moveSelection(by: -1)
            return true
        case 125 where controller.isShowing:      // Down
            controller.moveSelection(by: 1)
            return true
        case 116 where controller.isShowing:      // Page Up
            controller.moveSelection(by: -CompletionPopup.maximumVisibleRows)
            return true
        case 121 where controller.isShowing:      // Page Down
            controller.moveSelection(by: CompletionPopup.maximumVisibleRows)
            return true
        default:
            return false
        }
    }
}
