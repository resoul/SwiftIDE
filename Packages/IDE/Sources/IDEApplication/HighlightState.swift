import IDEDomain

/// The colours of one window of a document, kept right while the text changes under them.
///
/// Spans are computed for a version and a window; every edit after that moves, trims or splits
/// them, so what is on screen follows the text until the next result replaces it. Text inserted by
/// an edit has no span: it is plain until the highlighter has seen it.
public struct HighlightState: Sendable {
    /// The part of the document the spans describe. Empty when nothing was computed yet.
    public private(set) var window: Range<Int> = 0..<0
    public private(set) var spans: [HighlightSpan] = []
    /// Stretches whose colours changed but have not been redrawn. Sorted and not overlapping; they
    /// follow edits like the spans do. A change is redrawn when its text is in view.
    public private(set) var dirty: [Range<Int>] = []

    public init() {}

    public init(window: Range<Int>, spans: [HighlightSpan]) {
        self.window = window
        self.spans = spans
    }

    /// The spans that overlap `range`, in order.
    public func spans(overlapping range: Range<Int>) -> ArraySlice<HighlightSpan> {
        guard !range.isEmpty, !spans.isEmpty else { return [] }
        var low = 0, high = spans.count
        while low < high {   // the first span that ends after the range starts
            let middle = (low + high) / 2
            if spans[middle].end > range.lowerBound { high = middle } else { low = middle + 1 }
        }
        var end = low
        while end < spans.count, spans[end].location < range.upperBound { end += 1 }
        return spans[low..<end]
    }

    /// Follows one replacement, given in the coordinates of the text before it.
    public mutating func apply(edit range: UTF16TextRange, replacementLength: Int) {
        let start = range.location, oldEnd = range.location + range.length
        let delta = replacementLength - range.length
        guard !(delta == 0 && range.length == 0) else { return }

        // The window keeps covering what it covered, plus the inserted text; stretches awaiting a
        // redraw move the same way.
        if !window.isEmpty {
            window = Self.moved(window, start: start, oldEnd: oldEnd, delta: delta, replacementLength: replacementLength)
        }
        if !dirty.isEmpty {
            dirty = Self.merged(dirty.map {
                Self.moved($0, start: start, oldEnd: oldEnd, delta: delta, replacementLength: replacementLength)
            }.filter { !$0.isEmpty })
        }

        guard !spans.isEmpty else { return }
        // Spans that end at or before the edit are untouched; those that begin at or after its end
        // only move; the ones in between are cut around the replaced text.
        var first = 0, high = spans.count
        while first < high {
            let middle = (first + high) / 2
            if spans[middle].end > start { high = middle } else { first = middle + 1 }
        }
        var last = first   // the first span that begins at or after the end of the edit
        while last < spans.count, spans[last].location < oldEnd || (range.length == 0 && spans[last].location < start) {
            last += 1
        }
        var kept: [HighlightSpan] = []
        for span in spans[first..<last] {
            if span.location < start {
                kept.append(HighlightSpan(location: span.location, length: start - span.location, kind: span.kind))
            }
            if span.end > oldEnd {
                kept.append(HighlightSpan(
                    location: start + replacementLength, length: span.end - oldEnd, kind: span.kind
                ))
            }
        }
        if delta != 0 {
            for index in last..<spans.count { spans[index].location += delta }
        }
        spans.replaceSubrange(first..<last, with: kept)
    }

    /// Where a range lies after a replacement: unchanged before it, shifted after it, and when the
    /// replacement touches it, covering the inserted text too.
    static func moved(_ range: Range<Int>, start: Int, oldEnd: Int, delta: Int, replacementLength: Int) -> Range<Int> {
        let overlaps = range.lowerBound < oldEnd && range.upperBound > start
            || (oldEnd == start && range.lowerBound <= start && start <= range.upperBound)
        if overlaps {
            let lower = range.lowerBound <= start ? range.lowerBound : start
            let upper = range.upperBound >= oldEnd ? range.upperBound + delta : start + replacementLength
            return lower..<max(lower, upper)
        }
        if range.lowerBound >= oldEnd { return (range.lowerBound + delta)..<(range.upperBound + delta) }
        return range
    }

    private static func merged(_ ranges: [Range<Int>]) -> [Range<Int>] {
        var result: [Range<Int>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) where !range.isEmpty {
            if let last = result.last, last.upperBound >= range.lowerBound {
                result[result.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                result.append(range)
            }
        }
        return result
    }

    /// Notes that the colours of these stretches changed and are not drawn yet.
    public mutating func markDirty(_ ranges: [Range<Int>]) {
        dirty = Self.merged(dirty + ranges)
    }

    /// Takes out, and returns, the part of the stretches awaiting a redraw that lies inside `range`.
    public mutating func takeDirty(in range: Range<Int>) -> [Range<Int>] {
        guard !range.isEmpty, !dirty.isEmpty else { return [] }
        var taken: [Range<Int>] = [], remaining: [Range<Int>] = []
        for item in dirty {
            let lower = max(item.lowerBound, range.lowerBound), upper = min(item.upperBound, range.upperBound)
            guard lower < upper else { remaining.append(item); continue }
            taken.append(lower..<upper)
            if item.lowerBound < lower { remaining.append(item.lowerBound..<lower) }
            if upper < item.upperBound { remaining.append(upper..<item.upperBound) }
        }
        dirty = Self.merged(remaining)
        return Self.merged(taken)
    }

    /// Replaces the colours of `newWindow` with a fresh result and makes it the window. Returns the
    /// parts of it whose colours changed, so that only they need redrawing.
    @discardableResult
    public mutating func replace(window newWindow: Range<Int>, with fresh: [HighlightSpan]) -> [Range<Int>] {
        let changed = Self.differences(
            old: spans(overlapping: newWindow).map { clipped($0, to: newWindow) },
            new: fresh, in: newWindow
        )
        // What the old window had outside the new one is kept: it is still right for the text it
        // describes, and scrolling back finds it.
        var result: [HighlightSpan] = []
        for span in spans where span.end <= newWindow.lowerBound { result.append(span) }
        result.append(contentsOf: fresh)
        for span in spans where span.location >= newWindow.upperBound { result.append(span) }
        // Old spans that straddle the new window's edges keep their outside parts.
        for span in spans(overlapping: newWindow) {
            if span.location < newWindow.lowerBound {
                result.append(HighlightSpan(location: span.location, length: newWindow.lowerBound - span.location, kind: span.kind))
            }
            if span.end > newWindow.upperBound {
                result.append(HighlightSpan(location: newWindow.upperBound, length: span.end - newWindow.upperBound, kind: span.kind))
            }
        }
        result.sort { $0.location < $1.location }
        spans = result
        // The window is what the latest answer describes. Spans the old window had outside it stay
        // (they are what is still on screen there, and the baseline of the next comparison), but
        // they are not known to be right any more: an edit may have changed them.
        window = newWindow
        return changed
    }

    private func clipped(_ span: HighlightSpan, to range: Range<Int>) -> HighlightSpan {
        let start = max(span.location, range.lowerBound), end = min(span.end, range.upperBound)
        return HighlightSpan(location: start, length: end - start, kind: span.kind)
    }

    /// The stretches of `window` where the two span lists colour the text differently.
    static func differences(old: [HighlightSpan], new: [HighlightSpan], in window: Range<Int>) -> [Range<Int>] {
        var boundaries = Set<Int>([window.lowerBound, window.upperBound])
        for span in old { boundaries.insert(span.location); boundaries.insert(span.end) }
        for span in new { boundaries.insert(span.location); boundaries.insert(span.end) }
        let points = boundaries.filter { window.contains($0) || $0 == window.upperBound }.sorted()
        var changed: [Range<Int>] = []
        var oldIndex = 0, newIndex = 0
        for (lower, upper) in zip(points, points.dropFirst()) {
            while oldIndex < old.count, old[oldIndex].end <= lower { oldIndex += 1 }
            while newIndex < new.count, new[newIndex].end <= lower { newIndex += 1 }
            let oldKind = oldIndex < old.count && old[oldIndex].location <= lower ? old[oldIndex].kind : nil
            let newKind = newIndex < new.count && new[newIndex].location <= lower ? new[newIndex].kind : nil
            guard oldKind != newKind else { continue }
            if let previous = changed.last, previous.upperBound == lower {
                changed[changed.count - 1] = previous.lowerBound..<upper
            } else {
                changed.append(lower..<upper)
            }
        }
        return changed
    }
}
