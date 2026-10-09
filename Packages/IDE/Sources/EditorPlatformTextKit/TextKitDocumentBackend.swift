import AppKit
import IDEApplication

/// TextKit 2 storage/layout graph shared with the native NSTextView.
/// No mutable storage escapes to application or infrastructure consumers.
@MainActor
public final class TextKitDocumentBackend: DocumentEditingBackend {
    private let storage: NSTextStorage
    private let contentStorage: NSTextContentStorage
    private let textLayoutManager: NSTextLayoutManager
    private var hasTextView = false

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
    func makeTextView() -> NSTextView {
        precondition(!hasTextView, "One writable view per document")
        hasTextView = true
        // Building the view over an existing NSTextContainer that already has a
        // textLayoutManager selects TextKit 2 without ever touching `layoutManager`.
        let container = textLayoutManager.textContainer!
        container.widthTracksTextView = true
        return NSTextView(frame: .zero, textContainer: container)
    }

    public func commit(_ plan: PreparedDocumentEdit) {
        precondition(storage.string.utf8.elementsEqual(plan.sourceText.utf8))
        storage.beginEditing()
        defer { storage.endEditing() }
        for edit in plan.edits {
            storage.replaceCharacters(
                in: NSRange(location: edit.range.location, length: edit.range.length),
                with: edit.replacement
            )
        }
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
