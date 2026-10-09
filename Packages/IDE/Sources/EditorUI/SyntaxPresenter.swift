import AppKit
import IDEApplication
import IDEDomain

/// Draws a document's syntax colours as TextKit 2 rendering attributes (ADR-014, 007b).
///
/// A validator colours each layout fragment as TextKit lays it out, from the coordinator's current
/// state; nothing in the text, its revisions or its undo history is touched. When colours change
/// for text that is already laid out, the storage is told that attributes (not text) changed over
/// exactly those ranges, which makes TextKit validate them again.
@MainActor
public final class SyntaxPresenter {
    private let textView: NSTextView
    private let coordinator: SyntaxCoordinator
    private let theme: SyntaxTheme
    private let policy: SyntaxPolicy
    private var scrollObserver: NSObjectProtocol?
    private var frameObserver: NSObjectProtocol?
    private var observedClipView: NSClipView?
    private var viewportUpdateScheduled = false
    /// A viewport longer than this (one enormous line) is not asked about whole.
    private static let longestViewport = 20_000

    public init(
        textView: NSTextView, coordinator: SyntaxCoordinator,
        theme: SyntaxTheme = .standard, policy: SyntaxPolicy = .standard
    ) {
        self.textView = textView
        self.coordinator = coordinator
        self.theme = theme
        self.policy = policy
        textView.textLayoutManager?.renderingAttributesValidator = { [weak self] manager, fragment in
            MainActor.assumeIsolated { self?.validate(fragment, in: manager) }
        }
        coordinator.onChange = { [weak self] ranges in self?.refresh(ranges) }
    }

    isolated deinit {
        textView.textLayoutManager?.renderingAttributesValidator = nil
        coordinator.onChange = nil
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) }
    }

    // MARK: Following the view

    /// TextKit reuses text it already laid out when the view scrolls back to it, and then calls no
    /// validator: so scrolling itself must tell the coordinator what is in view, or text coloured
    /// before an edit would keep its old colours.
    private func observeScrolling() {
        guard let clipView = textView.enclosingScrollView?.contentView, clipView !== observedClipView else { return }
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        observedClipView = clipView
        clipView.postsBoundsChangedNotifications = true
        scheduleViewportUpdate()   // what is in view now, once the first layout is done
        // Edits that add or remove lines change what is in view without scrolling.
        textView.postsFrameChangedNotifications = true
        frameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: textView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleViewportUpdate() }
        }
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: clipView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleViewportUpdate() }
        }
    }

    /// Reads the viewport once things have been laid out, however many scroll events came.
    private func scheduleViewportUpdate() {
        guard !viewportUpdateScheduled else { return }
        viewportUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.updateViewport() }
        }
    }

    private func updateViewport() {
        viewportUpdateScheduled = false
        guard let manager = textView.textLayoutManager, let content = manager.textContentManager,
              let viewport = manager.textViewportLayoutController.viewportRange else { return }
        let start = content.offset(from: content.documentRange.location, to: viewport.location)
        let length = content.offset(from: viewport.location, to: viewport.endLocation)
        guard length > 0 else { return }
        coordinator.setVisible(start..<(start + min(length, Self.longestViewport)))
    }

    /// Called by TextKit for each fragment it lays out.
    private func validate(_ fragment: NSTextLayoutFragment, in manager: NSTextLayoutManager) {
        guard let content = manager.textContentManager else { return }
        observeScrolling()
        let origin = content.documentRange.location
        let start = content.offset(from: origin, to: fragment.rangeInElement.location)
        let length = content.offset(from: fragment.rangeInElement.location, to: fragment.rangeInElement.endLocation)
        // TextKit keeps a fragment's old rendering attributes when it validates it again.
        manager.removeRenderingAttribute(.foregroundColor, for: fragment.rangeInElement)
        guard length <= policy.maximumFragmentLength, length > 0 else { return }

        let fragmentRange = start..<(start + length)
        // The coordinator knows whether colours for this part of the text are known or on their way.
        coordinator.demand(fragmentRange)
        let spans = coordinator.state.spans(overlapping: fragmentRange)
        guard spans.count <= policy.maximumSpansPerFragment else { return }
        for span in spans {
            guard let colour = theme.colour(for: span.kind) else { continue }
            let from = max(span.location, fragmentRange.lowerBound), to = min(span.end, fragmentRange.upperBound)
            guard from < to,
                  let lower = content.location(fragment.rangeInElement.location, offsetBy: from - start),
                  let upper = content.location(lower, offsetBy: to - from),
                  let range = NSTextRange(location: lower, end: upper) else { continue }
            manager.setRenderingAttributes([.foregroundColor: colour], for: range)
        }
    }

    /// Makes TextKit validate these ranges again. Attribute-only: no revision, nothing to undo.
    private func refresh(_ ranges: [Range<Int>]) {
        guard let storage = textView.textStorage else { return }
        let length = storage.length
        storage.beginEditing()
        for range in ranges {
            // Ranges can reach past the end of a text that has become shorter.
            let lower = min(max(0, range.lowerBound), length), upper = min(max(lower, range.upperBound), length)
            guard lower < upper else { continue }
            storage.edited(.editedAttributes, range: NSRange(location: lower, length: upper - lower), changeInLength: 0)
        }
        storage.endEditing()
    }
}
