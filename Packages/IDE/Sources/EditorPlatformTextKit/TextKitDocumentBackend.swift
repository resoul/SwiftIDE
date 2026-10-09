import AppKit
import IDEApplication
import IDEDomain

@MainActor
public final class TextKitDocumentBackend: DocumentEditingBackend {
    let storage: NSTextStorage
    private let contentStorage: NSTextContentStorage
    private let textLayoutManager: NSTextLayoutManager
    private var hasTextView = false
    private var bridge: NativeEditingBridge?
    private var undoCoordinator: NativeUndoCoordinator?

    public init(loadedText: String) {
        storage = NSTextStorage(string: loadedText)
        contentStorage = NSTextContentStorage()
        textLayoutManager = NSTextLayoutManager()
        contentStorage.textStorage = storage
        contentStorage.addTextLayoutManager(textLayoutManager)
        textLayoutManager.textContainer = NSTextContainer(
            size: NSSize(width: 800, height: CGFloat.greatestFiniteMagnitude)
        )
    }

    public var text: String {
        // Materialize an independent value; mutable attributed storage is never a snapshot.
        String(decoding: storage.string.utf8, as: UTF8.self)
    }

    public var usesTextKit2: Bool {
        contentStorage.textLayoutManagers.contains { $0 === textLayoutManager }
    }

    /// Creates the single native view over this backend's own storage graph.
    /// A second view would need its own design for shared selection and undo.
    func makeTextView() -> CodeTextView {
        precondition(!hasTextView, "One writable view per document")
        hasTextView = true
        // Building the view over an existing NSTextContainer that already has a
        // textLayoutManager selects TextKit 2 without ever touching `layoutManager`.
        let container = textLayoutManager.textContainer!
        container.widthTracksTextView = true
        return CodeTextView(frame: .zero, textContainer: container)
    }

    /// Wires native input, undo and composition reporting for the one view. Done before the view
    /// can receive input, so every native mutation has a preflight and a reconciliation path.
    func installNativeEditing(on textView: CodeTextView) -> NativeUndoCoordinator {
        let undo = NativeUndoCoordinator(backend: self)
        let bridge = NativeEditingBridge(textView: textView, storage: storage, undo: undo)
        textView.delegate = bridge
        textView.bridge = bridge
        self.bridge = bridge
        self.undoCoordinator = undo
        return undo
    }

    public func attach(nativeEditReceiver: any NativeEditReceiver) {
        bridge?.receiver = nativeEditReceiver
    }

    public func endComposition() {
        bridge?.endComposition()
    }

    /// Applies edits known in advance (undo/redo steps) as one storage transaction. The session
    /// reconciles them like any native change, with exact replacements and undo/redo origin.
    func replaceManaged(_ edits: [DocumentEdit]) {
        bridge?.expect(exactEdits: edits)
        replace(edits)
        bridge?.selectEnd(of: edits)
        bridge?.breakTypingCoalescing()
    }

    private func replace(_ edits: [DocumentEdit]) {
        storage.beginEditing()
        defer { storage.endEditing() }
        for edit in edits.sorted(by: { $0.range.location > $1.range.location }) {
            storage.replaceCharacters(
                in: NSRange(location: edit.range.location, length: edit.range.length),
                with: edit.replacement
            )
        }
    }

    public func commit(_ plan: PreparedDocumentEdit) {
        precondition(storage.string.utf8.elementsEqual(plan.sourceText.utf8))
        replace(plan.edits)
        undoCoordinator?.registerProgrammatic(plan)
        bridge?.breakTypingCoalescing()
    }

    /// Presentation-only attributes must never create document revisions.
    public func setForegroundColor(_ color: NSColor, in range: NSRange) throws {
        guard range.location >= 0, range.length >= 0, range.location <= storage.length,
              range.length <= storage.length - range.location else {
            throw EditValidationError.invalidRange
        }
        storage.addAttribute(.foregroundColor, value: color, range: range)
    }
}
