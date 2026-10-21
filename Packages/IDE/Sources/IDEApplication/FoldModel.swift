import Foundation
import IDEDomain

/// A part of the text that can be folded: a header line and the lines below it that are hidden
/// while it is folded. The closing line (a `}` or `*/`) stays visible.
public struct FoldRegion: Equatable, Sendable {
    /// The zero-based line that stays visible, and where it starts (UTF-16 offset).
    public let startLine: Int
    public let headerStart: Int
    /// The last hidden line is `endLine - 1`; `endLine` holds the closing bracket.
    public let endLine: Int
    /// What is hidden, as UTF-16 offsets: from the start of the first line below the header up to
    /// the start of the closing line.
    public let hidden: Range<Int>

    public init(startLine: Int, headerStart: Int, endLine: Int, hidden: Range<Int>) {
        self.startLine = startLine
        self.headerStart = headerStart
        self.endLine = endLine
        self.hidden = hidden
    }
}

/// Which brackets make a foldable block.
public struct FoldPairs: OptionSet, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let braces = FoldPairs(rawValue: 1)
    public static let brackets = FoldPairs(rawValue: 2)
    public static let parentheses = FoldPairs(rawValue: 4)
}

/// Finds what can be folded: the blocks between `{` and `}` and the `/* … */` comments that run
/// over at least three lines (a header, one line or more to hide, and a closing line).
public enum FoldRegions {
    /// - Parameters:
    ///   - text: the document as UTF-16 units.
    ///   - characterLiterals: whether `'` opens a character literal (C family) or is just a mark.
    ///   - pairs: which brackets are blocks; only matching pairs fold.
    ///   - hashComments: whether `#` starts a comment that runs to the end of the line.
    public static func compute(
        in text: [UInt16],
        characterLiterals: Bool = false,
        pairs: FoldPairs = .braces,
        hashComments: Bool = false
    ) -> [FoldRegion] {
        var lineStarts = [0]
        var openers: [(line: Int, start: Int, closer: UInt16)] = []
        var found: [FoldRegion] = []
        var index = 0
        let count = text.count

        func close(startLine: Int, headerStart: Int, endLine: Int) {
            // Needs at least one line to hide between the header and the closing line.
            guard endLine - startLine >= 2 else { return }

            found.append(FoldRegion(
                startLine: startLine,
                headerStart: headerStart,
                endLine: endLine,
                hidden: lineStarts[startLine + 1]..<lineStarts[endLine]
            ))
        }

        while index < count {
            let unit = text[index]
            switch unit {
            case 0x0A:
                lineStarts.append(index + 1)
                index += 1
            case 0x0D:
                // CRLF is one terminator; a lone CR is one too.
                if self.unit(of: text, at: index + 1) == 0x0A { index += 1 }

                lineStarts.append(index + 1)
                index += 1
            case 0x23 where hashComments:
                while index < count, text[index] != 0x0A, text[index] != 0x0D { index += 1 }
            case 0x2F where self.unit(of: text, at: index + 1) == 0x2F:
                // A line comment runs to the end of the line.
                while index < count, text[index] != 0x0A, text[index] != 0x0D { index += 1 }
            case 0x2F where self.unit(of: text, at: index + 1) == 0x2A:
                let startLine = lineStarts.count - 1
                let headerStart = lineStarts[startLine]
                index += 2
                while index < count {
                    if text[index] == 0x2A, self.unit(of: text, at: index + 1) == 0x2F {
                        index += 2
                        break
                    }

                    if text[index] == 0x0A { lineStarts.append(index + 1) }
                    index += 1
                }
                close(startLine: startLine, headerStart: headerStart, endLine: lineStarts.count - 1)
            case 0x22:
                if self.unit(of: text, at: index + 1) == 0x22, self.unit(of: text, at: index + 2) == 0x22 {
                    // A triple-quoted string runs over lines until the next triple quote.
                    index += 3
                    while index < count {
                        if text[index] == 0x5C {
                            index += 2
                            continue
                        }

                        if text[index] == 0x22, self.unit(of: text, at: index + 1) == 0x22,
                           self.unit(of: text, at: index + 2) == 0x22 {
                            index += 3
                            break
                        }

                        if text[index] == 0x0A { lineStarts.append(index + 1) }
                        index += 1
                    }
                } else {
                    index += 1
                    while index < count, text[index] != 0x22, text[index] != 0x0A {
                        index += text[index] == 0x5C ? 2 : 1
                    }
                    if index < count, text[index] == 0x22 { index += 1 }
                }
            case 0x27 where characterLiterals:
                index += 1
                while index < count, text[index] != 0x27, text[index] != 0x0A {
                    index += text[index] == 0x5C ? 2 : 1
                }
                if index < count, text[index] == 0x27 { index += 1 }
            case 0x7B, 0x5B, 0x28:
                let kind: FoldPairs = unit == 0x7B ? .braces : (unit == 0x5B ? .brackets : .parentheses)
                if pairs.contains(kind) {
                    let startLine = lineStarts.count - 1
                    openers.append((
                        startLine,
                        lineStarts[startLine],
                        unit == 0x7B ? 0x7D : (unit == 0x5B ? 0x5D : 0x29)
                    ))
                }

                index += 1
            case 0x7D, 0x5D, 0x29:
                if let opener = openers.last, opener.closer == unit {
                    openers.removeLast()
                    close(startLine: opener.line, headerStart: opener.start, endLine: lineStarts.count - 1)
                }

                index += 1
            default:
                index += 1
            }
        }

        // Several blocks can open on one line: the folded one is the outermost.
        var best: [Int: FoldRegion] = [:]
        for region in found where region.endLine > (best[region.startLine]?.endLine ?? -1) {
            best[region.startLine] = region
        }

        return best.values.sorted { $0.startLine < $1.startLine }
    }

    private static func unit(of text: [UInt16], at position: Int) -> UInt16? {
        position < text.count ? text[position] : nil
    }
}

/// What is folded in one document, and which parts can be. It does not draw or lay out anything:
/// it says which UTF-16 ranges are hidden, and keeps them right while the text is edited.
@MainActor
public final class FoldModel {
    /// What can be folded now, top to bottom.
    public private(set) var regions: [FoldRegion] = []
    /// The folded regions: where their header starts and what they hide.
    public private(set) var folded: [(headerStart: Int, hidden: Range<Int>)] = []
    /// Called when the regions or the folds changed.
    public var onChange: (() -> Void)?

    public init() {}

    public var hiddenRanges: [Range<Int>] { folded.map(\.hidden) }

    public func isFolded(startLine: Int) -> Bool {
        guard let region = regions.first(where: { $0.startLine == startLine }) else { return false }

        return folded.contains { $0.headerStart == region.headerStart }
    }

    /// The regions after the text was read again. A fold stays if the same header still starts a
    /// region (its hidden range is taken from the new region); otherwise it is dropped.
    public func update(regions new: [FoldRegion]) {
        let keep = folded.compactMap { fold in
            new.first { $0.headerStart == fold.headerStart }.map { (headerStart: $0.headerStart, hidden: $0.hidden) }
        }
        let changed = regions != new || keep.count != folded.count || zip(keep, folded).contains {
            $0.hidden != $1.hidden
        }
        regions = new
        folded = keep
        if changed { onChange?() }
    }

    /// Folds the region that starts on `line`. Returns whether anything was folded.
    @discardableResult
    public func fold(startLine line: Int) -> Bool {
        guard let region = regions.first(where: { $0.startLine == line }), !isFolded(startLine: line) else {
            return false
        }

        folded.append((region.headerStart, region.hidden))
        onChange?()

        return true
    }

    @discardableResult
    public func unfold(startLine line: Int) -> Bool {
        guard let region = regions.first(where: { $0.startLine == line }),
              let position = folded.firstIndex(where: { $0.headerStart == region.headerStart }) else { return false }

        folded.remove(at: position)
        onChange?()

        return true
    }

    /// Opens the fold that hides `offset`, if there is one. Returns whether one was opened.
    @discardableResult
    public func unfoldHiding(offset: Int) -> Bool {
        guard let position = folded.firstIndex(where: { $0.hidden.contains(offset) }) else { return false }

        folded.remove(at: position)
        onChange?()

        return true
    }

    public func toggle(startLine line: Int) {
        if !unfold(startLine: line) { fold(startLine: line) }
    }

    public func unfoldAll() {
        guard !folded.isEmpty else { return }

        folded = []
        onChange?()
    }

    /// The innermost region that holds `line` (its header, its hidden lines or its closing line).
    public func region(containingLine line: Int) -> FoldRegion? {
        regions.filter { $0.startLine <= line && line <= $0.endLine }.max { $0.startLine < $1.startLine }
    }

    /// Follows an edit. A fold whose hidden text is touched is opened (typing there, undo, a
    /// reload); one whose header line is edited keeps its place; edits before shift it.
    public func apply(_ edits: [DocumentEdit]) {
        guard !folded.isEmpty else { return }

        var result: [(headerStart: Int, hidden: Range<Int>)] = []
        for fold in folded {
            var header = fold.headerStart
            var start = fold.hidden.lowerBound
            var end = fold.hidden.upperBound
            var dropped = false
            for edit in edits {
                let low = edit.range.location, high = low + edit.range.length
                let delta = edit.replacement.utf16.count - edit.range.length
                if high < header {
                    header += delta
                    start += delta
                    end += delta
                } else if low >= fold.hidden.upperBound {
                    continue
                } else if low >= fold.headerStart, high < fold.hidden.lowerBound,
                          !(edit.range.length == 0 && low == fold.headerStart && edit.replacement.contains("\n")) {
                    // The header line itself: the hidden text moves, the header stays.
                    start += delta
                    end += delta
                } else {
                    dropped = true
                    break
                }
            }
            if !dropped { result.append((header, start..<end)) }
        }
        let changed = result.count != folded.count || zip(result, folded).contains {
            $0.headerStart != $1.headerStart || $0.hidden != $1.hidden
        }
        folded = result
        if changed { onChange?() }
    }
}
