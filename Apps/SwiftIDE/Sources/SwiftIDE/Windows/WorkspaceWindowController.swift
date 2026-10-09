import AppKit
import EditorPlatformTextKit
import EditorUI
import IDEApplication

@MainActor
final class WorkspaceWindowController: NSWindowController {
    private let session: DocumentSession
    private let editor: TextKitEditor

    init(document: DocumentSession, editor: TextKitEditor) {
        self.session = document
        self.editor = editor
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = document.path
        window.contentView = EditorHostView(editor: editor)
        window.center()
        super.init(window: window)
        // Surface an unexpected TextKit 1 fallback instead of silently degrading.
        editor.compatibility.onFallback = { [weak window] in
            window?.subtitle = "⚠︎ TextKit 1 fallback"
            NSLog("SwiftIDE: NSTextView fell back to TextKit 1")
        }
        window.subtitle = editor.compatibility.isTextKit2 ? "TextKit 2" : "⚠︎ TextKit 1"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
