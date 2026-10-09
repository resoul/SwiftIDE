import AppKit

/// Result of building an editor: the backend and the view share one storage graph.
public struct TextKitEditor {
    public let backend: TextKitDocumentBackend
    public let textView: NSTextView
    public let compatibility: TextKitCompatibilityMonitor
    /// The document's single undo history, shared by native typing and programmatic edits.
    public let undo: NativeUndoCoordinator
}

@MainActor
public enum TextKitEditorFactory {
    public static func makeEditor(loadedText: String) -> TextKitEditor {
        let backend = TextKitDocumentBackend(loadedText: loadedText)
        let textView = backend.makeTextView()
        configureForCode(textView)
        let undo = backend.installNativeEditing(on: textView)
        let compatibility = TextKitCompatibilityMonitor(textView: textView)
        precondition(compatibility.isTextKit2, "NSTextView must start on TextKit 2")
        return TextKitEditor(backend: backend, textView: textView, compatibility: compatibility, undo: undo)
    }

    /// Plain text only; substitutions that rewrite source code are disabled explicitly.
    private static func configureForCode(_ textView: NSTextView) {
        textView.isRichText = false
        textView.importsGraphics = false
        textView.usesFontPanel = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        // Without this the view never grows past the height it was created with, and a long file
        // cannot be scrolled: the default limit is the initial frame.
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        textView.allowsUndo = true
    }
}
