import AppKit

extension NSTextView {
    /// Shows a small "…" box after the header line of each fold (`offsets` are the ends of those
    /// header lines, UTF-16); a click on one calls `onClick` with its offset. Does nothing for a
    /// text view that is not the editor's.
    @MainActor
    public func setFoldPlaceholders(_ offsets: [Int], onClick: @escaping (Int) -> Void) {
        guard let view = self as? CodeTextView else { return }

        view.foldPlaceholders = offsets
        view.onPlaceholderClick = onClick
    }

    /// The boxes that are drawn now, for tests: the offset each stands at and its frame.
    @MainActor
    public var foldPlaceholderFrames: [(offset: Int, frame: NSRect)] {
        (self as? CodeTextView)?.placeholderRects().map { ($0.offset, $0.rect) } ?? []
    }

    /// Clicks the box at `offset` as the mouse would; false if there is none.
    @MainActor
    @discardableResult
    public func clickFoldPlaceholder(at offset: Int) -> Bool {
        guard let view = self as? CodeTextView, view.foldPlaceholders.contains(offset) else { return false }

        view.onPlaceholderClick?(offset)

        return true
    }

    /// Marks tabs (an arrow across the tab) and spaces (a small dot) in the editor's text. Only how
    /// the text is drawn: the characters, their versions and Undo are untouched. Does nothing for a
    /// text view that is not the editor's.
    @MainActor
    public func setWhitespaceMarks(tabs: Bool, spaces: Bool) {
        (self as? CodeTextView)?.whitespaceMarks = (tabs, spaces)
    }

    /// The marked characters now in view and where their cells are, for tests.
    @MainActor
    public var whitespaceMarkFrames: [(offset: Int, isTab: Bool, frame: NSRect)] {
        (self as? CodeTextView)?.visibleWhitespaceMarks().map { ($0.offset, $0.kind == .tab, $0.frame) } ?? []
    }
}
