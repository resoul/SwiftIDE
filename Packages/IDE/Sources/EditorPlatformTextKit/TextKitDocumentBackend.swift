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
    private var storageObserver: NSObjectProtocol?
    public private(set) var editGeneration: UInt64 = 0
    /// How many times the whole text was copied out. Editing must keep this at zero.
    public private(set) var textMaterializations = 0

    public init(loadedText: String) {
        storage = NSTextStorage(string: loadedText)
        contentStorage = NSTextContentStorage()
        textLayoutManager = NSTextLayoutManager()
        contentStorage.textStorage = storage
        contentStorage.addTextLayoutManager(textLayoutManager)
        textLayoutManager.textContainer = NSTextContainer(
            size: NSSize(width: 800, height: CGFloat.greatestFiniteMagnitude)
        )
        // The only observer of storage passes: it counts them, then hands the pass to the bridge.
        // Counting first and in one place keeps the generation exact whoever edited the storage.
        storageObserver = NotificationCenter.default.addObserver(
            forName: NSTextStorage.didProcessEditingNotification, object: storage, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.storageDidProcessEditing() }
        }
    }

    isolated deinit {
        if let storageObserver { NotificationCenter.default.removeObserver(storageObserver) }
    }

    private func storageDidProcessEditing() {
        // Attribute-only passes are not text edits and create no revision.
        guard storage.editedMask.contains(.editedCharacters) else { return }
        editGeneration += 1
        bridge?.storageDidProcessEditing()
    }

    // MARK: Reading (editing path)

    public var utf16Length: Int { storage.length }

    public func utf16Unit(at index: Int) -> UInt16 {
        storage.mutableString.character(at: index)
    }

    public func substring(in range: UTF16TextRange) -> String {
        storage.mutableString.substring(with: NSRange(location: range.location, length: range.length))
    }

    // MARK: Reading (whole text)

    public var text: String {
        textMaterializations += 1
        // Materialize an independent value; mutable attributed storage is never a snapshot.
        return String(decoding: storage.string.utf8, as: UTF8.self)
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
        let bridge = NativeEditingBridge(textView: textView, backend: self, storage: storage, undo: undo)
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

    /// Applies an already validated plan as one storage transaction (an undo or redo step). The
    /// session accounts for it like any native change, with the exact edit and undo/redo origin.
    func replaceManaged(_ plan: PreparedDocumentEdit) {
        bridge?.expect(plan)
        replace(plan.edits)
        bridge?.selectEnd(of: plan.edits)
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
        precondition(storage.length == plan.sourceLength, "The plan was prepared against other text")
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
