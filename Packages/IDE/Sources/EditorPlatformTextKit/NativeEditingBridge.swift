import AppKit
import IDEApplication
import IDEDomain

/// Connects native NSTextView input to the session's single version/event path.
///
/// Before a managed edit: validate and capture exact replacements (`shouldChangeText`).
/// After storage processed it: tell the session, which verifies against the real backend text
/// and publishes one change. Nothing here ever writes characters back into storage.
@MainActor
final class NativeEditingBridge: NSObject, NSTextViewDelegate {
    weak var receiver: (any NativeEditReceiver)?
    var forcedOrigin: EditOrigin?
    private weak var textView: CodeTextView?
    private let storage: NSTextStorage
    private let undo: NativeUndoCoordinator
    private var pendingOrigin: EditOrigin?
    private var pendingExact: [DocumentEdit]?
    private var isComposingReported = false
    // One view-level input operation (insertText, setMarkedText, unmarkText) can touch storage
    // several times, e.g. unmarkText removes and re-inserts the marked text. Those passes are
    // folded into one commit so intermediate states never become revisions.
    private var coalesceDepth = 0
    private var coalescedEdits = 0
    private var coalescedOrigin: EditOrigin?
    private var coalescedExact: [DocumentEdit]?
    private var token: NSObjectProtocol?

    init(textView: CodeTextView, storage: NSTextStorage, undo: NativeUndoCoordinator) {
        self.textView = textView
        self.storage = storage
        self.undo = undo
        super.init()
        // Delivered synchronously while the storage finishes processing one outermost edit.
        token = NotificationCenter.default.addObserver(
            forName: NSTextStorage.didProcessEditingNotification, object: storage, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.storageDidProcessEditing() }
        }
    }

    isolated deinit {
        if let token { NotificationCenter.default.removeObserver(token) }
    }

    // MARK: Preflight

    func textView(
        _ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?
    ) -> Bool {
        self.textView(
            textView, shouldChangeTextInRanges: [NSValue(range: affectedCharRange)],
            replacementStrings: replacementString.map { [$0] }
        )
    }

    func textView(
        _ textView: NSTextView, shouldChangeTextInRanges affectedRanges: [NSValue],
        replacementStrings: [String]?
    ) -> Bool {
        // Attribute-only change: nothing to validate, no text event will follow.
        guard let replacementStrings, replacementStrings.count == affectedRanges.count else {
            return replacementStrings == nil
        }
        guard textView.isEditable, receiver?.allowsNativeEdit() ?? true else { return false }
        var edits: [DocumentEdit] = []
        for (value, replacement) in zip(affectedRanges, replacementStrings) {
            let range = value.rangeValue
            guard isValid(range) else { return false }
            edits.append(DocumentEdit(
                range: UTF16TextRange(location: range.location, length: range.length),
                replacement: replacement
            ))
        }
        pendingOrigin = resolveOrigin()
        pendingExact = edits
        return true
    }

    func textDidChange(_ notification: Notification) {
        pendingOrigin = nil
        pendingExact = nil
        syncComposition()
    }

    func undoManager(for view: NSTextView) -> UndoManager? {
        undo.undoManager
    }

    private func isValid(_ range: NSRange) -> Bool {
        guard range.location != NSNotFound, range.location >= 0, range.length >= 0,
              range.location <= storage.length, range.length <= storage.length - range.location else {
            return false
        }
        let string = storage.mutableString
        for boundary in [range.location, range.location + range.length] where boundary > 0 && boundary < storage.length {
            if UTF16.isLeadSurrogate(string.character(at: boundary - 1)),
               UTF16.isTrailSurrogate(string.character(at: boundary)) {
                return false
            }
        }
        return true
    }

    /// Captured when the operation starts: undo/redo state wins over typing/composition.
    private func resolveOrigin() -> EditOrigin {
        if undo.undoManager.isUndoing { return .undo }
        if undo.undoManager.isRedoing { return .redo }
        if let forcedOrigin { return forcedOrigin }
        return textView?.hasMarkedText() == true ? .composition : .typing
    }

    // MARK: Verification and hand-off

    private func storageDidProcessEditing() {
        // Attribute-only passes create no text revision.
        guard storage.editedMask.contains(.editedCharacters) else { return }
        let origin = pendingOrigin ?? resolveOrigin()
        let exact = pendingExact
        pendingOrigin = nil
        pendingExact = nil
        if coalesceDepth > 0 {
            coalescedEdits += 1
            if coalescedEdits == 1 {
                coalescedOrigin = origin
                coalescedExact = exact
            } else {
                // Several storage passes: no single exact log, let the session diff the result.
                coalescedExact = nil
            }
            return
        }
        receiver?.nativeEditDidCommit(NativeEditCommit(origin: origin, exactEdits: exact))
    }

    /// Runs one AppKit input operation and reports its net text effect as at most one commit.
    func performCoalesced(_ operation: () -> Void) {
        coalesceDepth += 1
        operation()
        coalesceDepth -= 1
        guard coalesceDepth == 0, coalescedEdits > 0, let origin = coalescedOrigin else { return }
        let exact = coalescedExact
        coalescedEdits = 0
        coalescedOrigin = nil
        coalescedExact = nil
        receiver?.nativeEditDidCommit(NativeEditCommit(origin: origin, exactEdits: exact))
    }

    /// Edits applied by the undo coordinator are known exactly; announce them before mutating.
    func expect(exactEdits: [DocumentEdit]) {
        pendingExact = exactEdits
    }

    /// A programmatic change ends the current typing run: the next keystroke must register its
    /// own undo action instead of extending one made before the change.
    func breakTypingCoalescing() {
        textView?.breakUndoCoalescing()
    }

    func selectEnd(of edits: [DocumentEdit]) {
        guard let last = edits.min(by: { $0.range.location < $1.range.location }) else { return }
        let end = last.range.location + last.replacement.utf16.count
        textView?.setSelectedRange(NSRange(location: min(end, storage.length), length: 0))
    }

    // MARK: Composition

    func beginMarkedTextUpdate(isEmpty: Bool) -> Bool {
        let was = isComposingReported
        if !was, !isEmpty {
            isComposingReported = true
            receiver?.compositionDidChange(.began)
        }
        return was
    }

    func finishMarkedTextUpdate(wasComposing: Bool) {
        if wasComposing, textView?.hasMarkedText() == true {
            receiver?.compositionDidChange(.updated)
        }
        syncComposition()
    }

    /// Reports begin/end transitions that did not pass through `setMarkedText`.
    /// Ending without a text change still notifies, so waiting saves resume.
    func syncComposition() {
        let actual = textView?.hasMarkedText() == true
        if actual, !isComposingReported {
            isComposingReported = true
            receiver?.compositionDidChange(.began)
        } else if !actual, isComposingReported {
            isComposingReported = false
            receiver?.compositionDidChange(.ended)
        }
    }

    func endComposition() {
        guard let textView else { return }
        textView.inputContext?.discardMarkedText()
        if textView.hasMarkedText() { textView.unmarkText() }
        syncComposition()
    }
}
