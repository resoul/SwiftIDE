import AppKit
import IDEApplication
import IDEDomain

/// Connects native NSTextView input to the session's single version/event path.
///
/// Before an edit: validate it and note what it replaces (`shouldChangeText`).
/// After storage processed it: describe the change from the storage's own edited range and tell
/// the session, which brings its version up to date and publishes one change. The cost of all of
/// this is proportional to the edit, never to the document. Nothing here ever writes characters
/// back into storage.
@MainActor
final class NativeEditingBridge: NSObject, NSTextViewDelegate {
    weak var receiver: (any NativeEditReceiver)?
    var forcedOrigin: EditOrigin?
    private weak var textView: CodeTextView?
    private unowned let backend: TextKitDocumentBackend
    private let storage: NSTextStorage
    private let undo: NativeUndoCoordinator

    /// What the preflight learned about the edit that is about to happen.
    private struct Pending {
        var edits: [DocumentEdit]
        var replaced: [String]
        /// For a single edit: the paragraph around it as it was, so that after the pass it can be
        /// checked that the declared edit is all that changed there. Absent for very long
        /// paragraphs, where the region storage reports is used instead.
        var context: (range: NSRange, text: String)?
    }

    /// Paragraphs longer than this are not copied at preflight.
    private static let maximumContext = 64 * 1024

    private var pendingOrigin: EditOrigin?
    private var pending: Pending?
    private var isComposingReported = false

    // One view-level input operation (insertText, setMarkedText, unmarkText) can touch storage
    // several times, e.g. unmarkText removes and re-inserts the marked text. Those passes are
    // folded into one commit so intermediate states never become revisions.
    private var coalesceDepth = 0
    private var coalescedPasses = 0
    private var coalescedOrigin: EditOrigin?
    private var coalescedFirstEffect: NativeTextEffect?
    private var region = EditRegionAccumulator()

    init(textView: CodeTextView, backend: TextKitDocumentBackend, storage: NSTextStorage, undo: NativeUndoCoordinator) {
        self.textView = textView
        self.backend = backend
        self.storage = storage
        self.undo = undo
        super.init()
    }

    // MARK: Preflight

    func textView(
        _ textView: NSTextView,
        shouldChangeTextIn affectedCharRange: NSRange,
        replacementString: String?
    ) -> Bool {
        self.textView(
            textView,
            shouldChangeTextInRanges: [NSValue(range: affectedCharRange)],
            replacementStrings: replacementString.map { [$0] }
        )
    }

    func textView(
        _ textView: NSTextView,
        shouldChangeTextInRanges affectedRanges: [NSValue],
        replacementStrings: [String]?
    ) -> Bool {
        // Attribute-only change: nothing to validate, no text event will follow.
        guard let replacementStrings, replacementStrings.count == affectedRanges.count else {
            return replacementStrings == nil
        }

        guard textView.isEditable, receiver?.allowsNativeEdit() ?? true else { return false }

        var edits: [DocumentEdit] = []
        var replaced: [String] = []
        for (value, replacement) in zip(affectedRanges, replacementStrings) {
            let range = value.rangeValue
            guard isValid(range) else { return false }

            edits.append(DocumentEdit(
                range: UTF16TextRange(location: range.location, length: range.length),
                replacement: replacement
            ))
            replaced.append(storage.mutableString.substring(with: range))
        }
        pendingOrigin = resolveOrigin()
        pending = makePending(edits: edits, replaced: replaced)

        return true
    }

    func textDidChange(_ notification: Notification) {
        pendingOrigin = nil
        pending = nil
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

    // MARK: Describing and handing off a change

    /// Called by the backend for every storage pass that changed characters, after it counted it.
    func storageDidProcessEditing() {
        let edited = storage.editedRange
        let delta = storage.changeInLength
        let origin = pendingOrigin ?? resolveOrigin()
        let known = pending
        pendingOrigin = nil
        pending = nil

        if coalesceDepth > 0 {
            coalescedPasses += 1
            if coalescedPasses == 1 {
                coalescedOrigin = origin
                coalescedFirstEffect = effect(edited: edited, delta: delta, known: known)
            }

            region.record(
                editedRange: UTF16TextRange(location: edited.location, length: edited.length),
                changeInLength: delta
            )

            return
        }

        send(origin: origin, effect: effect(edited: edited, delta: delta, known: known), passes: 1)
    }

    /// The change as one replacement in coordinates of the text before this pass.
    private func effect(edited: NSRange, delta: Int, known: Pending?) -> NativeTextEffect {
        if let exact = confirmedEdit(edited: edited, delta: delta, known: known) { return exact }
        // Otherwise storage's own report: the edited range now holds the new text, and held
        // `length - delta` characters before. It covers every change, but may include text that
        // did not change.
        let beforeLength = edited.length - delta
        guard beforeLength >= 0 else { return .unknown }

        return .replaced(
            range: UTF16TextRange(location: edited.location, length: beforeLength),
            replacement: storage.mutableString.substring(with: edited),
            isExact: false
        )
    }

    /// The declared edit, if the content of its paragraph proves nothing else changed there.
    ///
    /// Storage widens the edited range beyond the typed text (attribute fixing reaches the end of
    /// the paragraph), so a range that merely covers the edit proves nothing: something else may
    /// have changed inside it. Comparing the paragraph with what it would be after exactly the
    /// declared edit settles it, at a cost proportional to the paragraph.
    private func confirmedEdit(edited: NSRange, delta: Int, known: Pending?) -> NativeTextEffect? {
        guard let known, known.edits.count == 1, let context = known.context else { return nil }

        let edit = known.edits[0]
        let inserted = edit.replacement.utf16.count
        guard delta == inserted - edit.range.length else { return nil }

        let after = NSRange(location: context.range.location, length: context.range.length + delta)
        guard after.length >= 0, NSMaxRange(after) <= storage.length,
              edited.location >= after.location, NSMaxRange(edited) <= NSMaxRange(after) else { return nil }

        let expected = NSMutableString(string: context.text)
        expected.replaceCharacters(
            in: NSRange(location: edit.range.location - context.range.location, length: edit.range.length),
            with: edit.replacement
        )
        guard (expected as String).utf8.elementsEqual(storage.mutableString.substring(with: after).utf8) else {
            return nil
        }

        if known.replaced[0].utf8.elementsEqual(edit.replacement.utf8) { return .unchanged }

        return .replaced(range: edit.range, replacement: edit.replacement, isExact: true)
    }

    private func send(origin: EditOrigin, effect: NativeTextEffect, passes: Int) {
        receiver?.nativeEditDidCommit(NativeEditCommit(
            origin: origin,
            effect: effect,
            passes: passes,
            generation: backend.editGeneration
        ))
    }

    /// Runs one AppKit input operation and reports its net text effect as at most one commit.
    /// `unmarking` is the marked range of an `unmarkText`: removing and re-inserting the same text
    /// there is not an edit.
    func performCoalesced(unmarking marked: NSRange? = nil, _ operation: () -> Void) {
        let outermost = coalesceDepth == 0
        var markedBefore: (length: Int, text: String)?
        if outermost, let marked, marked.location != NSNotFound, isValid(marked) {
            markedBefore = (storage.length, storage.mutableString.substring(with: marked))
        }

        coalesceDepth += 1
        operation()
        coalesceDepth -= 1
        guard coalesceDepth == 0, coalescedPasses > 0, let origin = coalescedOrigin else { return }

        let passes = coalescedPasses
        var effect: NativeTextEffect
        if let marked, let markedBefore, storage.length == markedBefore.length,
           region.isInside(UTF16TextRange(location: marked.location, length: marked.length)),
           storage.mutableString.substring(with: marked) == markedBefore.text {
            effect = .unchanged
        } else if passes == 1, let first = coalescedFirstEffect {
            effect = first
        } else {
            let before = region.rangeBefore
            effect = before.length >= 0
                ? .replaced(
                    range: before,
                    replacement: storage.mutableString.substring(
                        with: NSRange(location: region.rangeAfter.location, length: region.rangeAfter.length)
                    ),
                    isExact: false
                )
                : .unknown
        }

        coalescedPasses = 0
        coalescedOrigin = nil
        coalescedFirstEffect = nil
        region = EditRegionAccumulator()
        send(origin: origin, effect: effect, passes: passes)
    }

    /// Edits applied by the undo coordinator are known exactly; announce them before mutating.
    func expect(_ plan: PreparedDocumentEdit) {
        pending = makePending(edits: plan.edits, replaced: plan.replaced)
    }

    /// Must run before storage changes: it records the paragraph as it is now.
    private func makePending(edits: [DocumentEdit], replaced: [String]) -> Pending {
        var context: (range: NSRange, text: String)?
        if edits.count == 1 {
            let range = NSRange(location: edits[0].range.location, length: edits[0].range.length)
            let paragraph = storage.mutableString.paragraphRange(for: range)
            if paragraph.length <= Self.maximumContext {
                context = (paragraph, storage.mutableString.substring(with: paragraph))
            }
        }

        return Pending(edits: edits, replaced: replaced, context: context)
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
        // Inside a view-level operation the marked text may be momentarily gone (unmarkText takes
        // it out and puts it back) and the session has not yet been told what changed. Reporting
        // now would announce an end nobody can look at consistently; the operation reports its
        // final state when it finishes.
        guard coalesceDepth == 0 else { return }

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
