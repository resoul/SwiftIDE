import Foundation
import IDEDomain

/// Keeps the colours of one open document: tells a highlighter about every edit, asks it for the
/// part of the text that is on screen, and holds the answer in a `HighlightState` that follows
/// the text until the next answer.
///
/// All of it is cheap on the main thread: edits cost the edit, the state costs its spans, and the
/// parsing happens in the highlighter, off this thread. A result is used only if the document is
/// still at the version it was computed for; otherwise a newer request is already on its way.
@MainActor
public final class SyntaxCoordinator {
    public private(set) var state = HighlightState()
    /// Called with the ranges, in the current text, whose colours just changed.
    public var onChange: (@MainActor ([Range<Int>]) -> Void)?
    /// How many times the highlighter had to start over from the text (it lost track of an edit).
    public private(set) var resyncCount = 0
    /// The version of the latest result that was applied; for measuring how far colours lag.
    public private(set) var lastResultVersion: UInt64?

    private let session: DocumentSession
    private let source: any TextSource
    private let highlighter: any SyntaxHighlighter
    private let margin: Int
    /// The version the highlighter's copy of the text is at; nil when it must start over.
    private var trackedVersion: UInt64?
    /// What the view shows, as set by `setVisible`. It can be out of date after the text changed,
    /// so it is always clamped to the text before it is used.
    private var visible: Range<Int> = 0..<0
    private var requested: (version: UInt64, window: Range<Int>)?
    /// The version the state's window was last computed for. After an edit the window still follows
    /// the text, but its colours are those of the old text until an answer for the new version.
    private var windowVersion: UInt64?
    private var subscription: UUID?
    private var compositionSubscription: UUID?
    private var isStopped = false

    public var isComposing: Bool { session.isComposing }

    /// `margin` is how far beyond the visible text colours are computed, so that scrolling a little
    /// shows coloured text at once.
    public init(session: DocumentSession, source: any TextSource, highlighter: any SyntaxHighlighter, margin: Int = 6_000) {
        self.session = session
        self.source = source
        self.highlighter = highlighter
        self.margin = margin
        highlighter.connect { [weak self] result in
            Task { @MainActor in self?.receive(result) }
        }
        sendText()
        subscription = session.subscribeToChanges { [weak self] changes in
            self?.documentDidChange(changes)
        }
        compositionSubscription = session.subscribeToComposition { [weak self] event in
            self?.compositionDidChange(event)
        }
        request(around: visible, force: true)
    }

    isolated deinit {
        stop()
    }

    /// Stops following the document and lets the highlighter go of its tree and text. Idempotent;
    /// nothing is sent to the highlighter afterwards and its late answers are ignored.
    public func stop() {
        guard !isStopped else { return }
        isStopped = true
        if let subscription { session.unsubscribeFromChanges(subscription) }
        if let compositionSubscription { session.unsubscribeFromComposition(compositionSubscription) }
        subscription = nil
        compositionSubscription = nil
        highlighter.stop()
    }

    /// The text on screen changed (scrolling, resizing). Colours are asked for if the new view is
    /// not covered by what is known.
    public func setVisible(_ range: Range<Int>) {
        visible = range
        request(around: range, force: false)
        redrawWhatIsInView()
    }

    /// Something laid out needs colours (a fragment outside what is known): asks for them without
    /// moving what counts as visible.
    public func demand(_ range: Range<Int>) {
        request(around: range, force: false)
    }

    // MARK: Following the document

    private func documentDidChange(_ changes: DocumentChangeSet) {
        guard changes.oldVersion == trackedVersion else { return resynchronise() }
        for edit in changes.edits {   // last position first, as the state expects
            let replacementLength = edit.replacement.utf16.count
            state.apply(edit: edit.range, replacementLength: replacementLength)
            // What is in view moves with the text, until the view reports it again.
            if !visible.isEmpty, replacementLength != edit.range.length || edit.range.length > 0 {
                visible = HighlightState.moved(
                    visible, start: edit.range.location, oldEnd: edit.range.location + edit.range.length,
                    delta: replacementLength - edit.range.length, replacementLength: replacementLength
                )
            }
        }
        highlighter.edit(changes)
        trackedVersion = changes.newVersion
        request(around: visible, force: true)
    }

    /// Hands the highlighter the whole text again. For the start, and for a lost edit.
    private func sendText() {
        var chunks: [[UInt16]] = []
        source.enumerateUTF16(in: UTF16TextRange(location: 0, length: source.utf16Length)) { units in
            chunks.append(Array(units))
        }
        highlighter.reset(text: chunks, version: session.version)
        windowVersion = nil
        // A backend that is ahead of the session (an edit not yet accounted for) has text that
        // does not belong to this version; the next change set will say so and start over.
        trackedVersion = source.utf16Length == session.utf16Length ? session.version : nil
        requested = nil
    }

    private func resynchronise() {
        resyncCount += 1
        state = HighlightState()
        sendText()
        request(around: visible, force: true)
    }

    // MARK: Asking and receiving

    /// Asks for the colours of `basis` and a margin around it, unless they are known for this
    /// version or already on their way. `force` asks anyway: the version just changed.
    private func request(around basis: Range<Int>, force: Bool) {
        guard !isStopped, let version = trackedVersion, version == session.version else { return }
        let length = session.utf16Length
        // Ranges handed in can predate an edit that shortened the text: clamp them to it.
        let lower = min(max(0, basis.lowerBound), length)
        let upper = min(max(lower, basis.upperBound), length)
        let clamped = lower..<upper
        let around = clamped.isEmpty ? 0..<min(length, margin) : clamped
        let window = max(0, around.lowerBound - margin)..<min(length, around.upperBound + margin)
        if !force, !clamped.isEmpty {
            if windowVersion == version, state.window.lowerBound <= clamped.lowerBound, clamped.upperBound <= state.window.upperBound { return }
            if let requested, requested.version == version, requested.window.lowerBound <= clamped.lowerBound,
               clamped.upperBound <= requested.window.upperBound { return }
        }
        requested = (version, window)
        highlighter.requestHighlights(in: window, version: version)
    }

    private func receive(_ result: HighlightResult) {
        guard !isStopped, result.version == session.version, trackedVersion == result.version else { return }
        guard result.documentLength == session.utf16Length else { return resynchronise() }
        lastResultVersion = result.version
        windowVersion = result.version
        let changed = state.replace(window: result.window, with: result.spans)
        state.markDirty(changed)
        redrawWhatIsInView()
    }

    /// Hands the presenter the changed stretches that are in view. Others wait: redrawing text
    /// that is not shown is wasted work, and invalidating far fragments while the view sits at the
    /// end of a long document made TextKit lose the last lines. Nothing is redrawn while an input
    /// method holds marked text, which is not known to survive it.
    private func redrawWhatIsInView() {
        guard !session.isComposing, !state.dirty.isEmpty else { return }
        let length = session.utf16Length
        let lower = min(max(0, visible.lowerBound), length)
        let inView = lower..<min(length, max(lower, visible.upperBound))
        let due = state.takeDirty(in: inView)
        if !due.isEmpty { onChange?(due) }
    }

    private func compositionDidChange(_ event: CompositionEvent) {
        if event == .ended { redrawWhatIsInView() }
    }
}
