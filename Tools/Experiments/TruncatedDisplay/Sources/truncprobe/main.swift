import AppKit
import Foundation

// A throwaway probe for TK-013: does "show only the start of a long line, keep the text whole"
// work with TextKit 2 through the content storage delegate, and what happens to selection,
// copy, caret movement, scrolling, hit testing and line rows when part of a paragraph is not laid out?

alarm(90)   // a hang ends the process; the outer guard also watches memory

func ms(_ body: () -> Void) -> Double {
    let d = ContinuousClock().measure(body)
    return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
}
func rssMB() -> Int {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) } }
    return kr == KERN_SUCCESS ? Int(info.resident_size / 1_048_576) : -1
}
func line(_ s: String) { print("[\(rssMB()) MB] " + s); fflush(stdout) }

let args = CommandLine.arguments
let kilobytes = Int(args.count > 1 ? args[1] : "") ?? 100
let mode = args.count > 2 ? args[2] : "1"      // 0 plain, 1 delegate substitution, 2 hidden element
let truncated = mode == "1"
let limit = Int(ProcessInfo.processInfo.environment["LIMIT"] ?? "") ?? 2000

final class Truncator: NSObject, NSTextContentStorageDelegate {
    var limit: Int
    var calls = 0
    init(limit: Int) { self.limit = limit }
    func textContentStorage(_ storage: NSTextContentStorage, textParagraphWith range: NSRange) -> NSTextParagraph? {
        calls += 1
        guard range.length > limit, let source = storage.textStorage else { return nil }
        let head = source.attributedSubstring(from: NSRange(location: range.location, length: limit)).mutableCopy() as! NSMutableAttributedString
        var attrs = head.attributes(at: 0, effectiveRange: nil)
        attrs[.foregroundColor] = NSColor.secondaryLabelColor
        head.append(NSAttributedString(string: " … (\(range.length - limit) more characters)", attributes: attrs))
        // keep a trailing line break out of it: a paragraph here is the text without its separator
        return NSTextParagraph(attributedString: head)
    }
}

/// Mode 2: the paragraph is handed over as two elements with true ranges: its start, and the hidden rest.
class Piece: NSTextParagraph {
    nonisolated(unsafe) var content: NSTextRange?
    nonisolated(unsafe) var separator: NSTextRange?
    nonisolated(unsafe) var hidden = false
    override var paragraphContentRange: NSTextRange? { content }
    override var paragraphSeparatorRange: NSTextRange? { separator }
}

final class HidingContentStorage: NSTextContentStorage {
    nonisolated(unsafe) var limit = 2000
    nonisolated(unsafe) var cache: [String: [Piece]] = [:]

    override func attributedString(for textElement: NSTextElement) -> NSAttributedString? {
        if let piece = textElement as? Piece { return piece.attributedString }
        return super.attributedString(for: textElement)
    }

    override func enumerateTextElements(from textLocation: NSTextLocation?, options: NSTextContentManager.EnumerationOptions = [], using block: (NSTextElement) -> Bool) -> NSTextLocation? {
        var stoppedInside: NSTextLocation?
        let reverse = options.contains(.reverse)
        let ended = super.enumerateTextElements(from: textLocation, options: options) { element in
            guard let paragraph = element as? NSTextParagraph, let range = paragraph.elementRange,
                  paragraph.attributedString.length > limit else { return block(element) }
            let text = paragraph.attributedString
            let key = "\(offset(from: documentRange.location, to: range.location))-\(text.length)"
            var pieces = cache[key]
            if pieces == nil {
                var made: [Piece] = []
                for (start, end, hidden) in [(0, limit, false), (limit, text.length, true)] {
                    let piece = Piece(attributedString: text.attributedSubstring(from: NSRange(location: start, length: end - start)))
                    guard let from = location(range.location, offsetBy: start), let to = location(range.location, offsetBy: end) else { continue }
                    piece.elementRange = NSTextRange(location: from, end: to)
                    if hidden, let contentRange = paragraph.paragraphContentRange {
                        piece.content = NSTextRange(location: from, end: contentRange.endLocation)
                        piece.separator = paragraph.paragraphSeparatorRange
                    } else {
                        piece.content = NSTextRange(location: from, end: to)
                        piece.separator = NSTextRange(location: to, end: to)
                    }
                    piece.hidden = hidden
                    piece.textContentManager = self
                    made.append(piece)
                }
                cache[key] = made
                pieces = made
            }
            var chosen = pieces ?? []
            if let textLocation {
                let relative = offset(from: range.location, to: textLocation)
                chosen = chosen.filter { piece in
                    guard let r = piece.elementRange else { return true }
                    let start = offset(from: range.location, to: r.location), end = offset(from: range.location, to: r.endLocation)
                    if reverse { return start < relative || (relative <= 0 && start == 0) }
                    return end > relative || (piece === chosen.last && relative >= end)
                }
            }
            if reverse { chosen.reverse() }
            for piece in chosen where !block(piece) {
                stoppedInside = reverse ? piece.elementRange?.location : piece.elementRange?.endLocation
                return false
            }
            return true
        }
        return stoppedInside ?? ended
    }
}

/// A layout fragment that lays nothing out.
final class EmptyFragment: NSTextLayoutFragment {
    nonisolated(unsafe) static var asked = 0
    override var textLineFragments: [NSTextLineFragment] { Self.asked += 1; return [] }
    override var layoutFragmentFrame: CGRect { CGRect(x: 0, y: super.layoutFragmentFrame.minY, width: 0, height: 0) }
    override var renderingSurfaceBounds: CGRect { .zero }
}

final class HidingDelegate: NSObject, NSTextLayoutManagerDelegate {
    func textLayoutManager(_ manager: NSTextLayoutManager, textLayoutFragmentFor location: NSTextLocation, in textElement: NSTextElement) -> NSTextLayoutFragment {
        if let piece = textElement as? Piece, piece.hidden { return EmptyFragment(textElement: textElement, range: textElement.elementRange) }
        return NSTextLayoutFragment(textElement: textElement, range: textElement.elementRange)
    }
}

// Document: 5 short lines, one long line, 5 short lines.
var words = ""
var n = 0
while words.utf16.count < kilobytes * 1024 { words += "word\(n) "; n += 1 }
let shortLines = (1...5).map { "short line \($0)" }.joined(separator: "\n")
let text = shortLines + "\n" + words + "\n" + (6...10).map { "tail line \($0)" }.joined(separator: "\n") + "\n"
let longStart = (shortLines + "\n").utf16.count
let longLength = words.utf16.count

let textView: NSTextView
nonisolated(unsafe) let hidingDelegate = HidingDelegate()
if mode == "2" {
    let storage = HidingContentStorage()
    storage.limit = limit
    let manager = NSTextLayoutManager()
    manager.delegate = hidingDelegate
    storage.addTextLayoutManager(manager)
    let container = NSTextContainer(size: NSSize(width: 760, height: CGFloat.greatestFiniteMagnitude))
    manager.textContainer = container
    storage.textStorage = NSTextStorage()
    textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 760, height: 500), textContainer: container)
} else {
    textView = NSTextView(usingTextLayoutManager: true)
}
let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 760, height: 500))
scroll.documentView = textView
scroll.hasVerticalScroller = true
textView.minSize = NSSize(width: 0, height: 0)
textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
textView.isVerticallyResizable = true
textView.isHorizontallyResizable = false
textView.autoresizingMask = [.width]
textView.frame = NSRect(x: 0, y: 0, width: 760, height: 500)
textView.textContainer?.containerSize = NSSize(width: 760, height: CGFloat.greatestFiniteMagnitude)
textView.textContainer?.widthTracksTextView = true
textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
window.contentView = scroll
let truncator = Truncator(limit: limit)
guard let contentStorage = textView.textLayoutManager?.textContentManager as? NSTextContentStorage,
      let layout = textView.textLayoutManager else { fatalError("not TextKit 2") }
if truncated { contentStorage.delegate = truncator }
textView.string = text
textView.isEditable = false
textView.isSelectable = true
window.makeFirstResponder(textView)
line("probe: \(kilobytes) KB line, mode=\(mode), visible=\(limit) chars; storage \(textView.string.utf16.count) units; long line at \(longStart)+\(longLength)")

// 1. layout cost and shape
let layoutMs = ms { layout.ensureLayout(for: layout.documentRange) }
textView.sizeToFit()
line("1 layout: \(String(format: "%.1f", layoutMs)) ms; document height \(Int(layout.usageBoundsForTextContainer.height)); delegate calls \(truncator.calls)")

// 2. elements and fragments
var fragments: [(start: Int, end: Int, rows: Int, frameHeight: Int)] = []
layout.enumerateTextLayoutFragments(from: layout.documentRange.location, options: [.ensuresLayout]) { f in
    let doc = layout.documentRange.location
    let s = layout.offset(from: doc, to: f.rangeInElement.location)
    let e = layout.offset(from: doc, to: f.rangeInElement.endLocation)
    fragments.append((s, e, f.textLineFragments.count, Int(f.layoutFragmentFrame.height)))
    return true
}
line("2 fragments: \(fragments.count); the long one: " + (fragments.first { $0.start == longStart }.map { "range \($0.start)..<\($0.end) rows \($0.rows) height \($0.frameHeight)" } ?? "missing"))
let rowsByLine = fragments.map { "\($0.start):\($0.rows)" }.joined(separator: " ")
line("  rows by fragment start: \(rowsByLine)")
var elementLengths: [String] = []
_ = contentStorage.enumerateTextElements(from: nil, options: []) { el in
    if let p = el as? NSTextParagraph, let r = el.elementRange {
        let s = contentStorage.offset(from: contentStorage.documentRange.location, to: r.location)
        let e = contentStorage.offset(from: contentStorage.documentRange.location, to: r.endLocation)
        if e - s > 100 || p.attributedString.length != e - s { elementLengths.append("\(s)..<\(e) attributed \(p.attributedString.length)") }
    }
    return true
}
line("  elements whose attributed length differs from their range: \(elementLengths)")

// 3. selection and geometry inside the hidden part
@MainActor func describe(_ r: NSRange) { autoreleasepool { describeInner(r) } }
@MainActor func describeInner(_ r: NSRange) {
    let rect = textView.firstRect(forCharacterRange: r, actualRange: nil)
    var segs: [CGRect] = []
    if let start = layout.location(layout.documentRange.location, offsetBy: r.location),
       let end = layout.location(start, offsetBy: r.length), let tr = NSTextRange(location: start, end: end) {
        layout.enumerateTextSegments(in: tr, type: .selection, options: []) { _, rect, _, _ in segs.append(rect); return true }
    }
    line("  range \(r.location)+\(r.length): firstRect (screen) \(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))x\(Int(rect.height)); segments \(segs.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" })")
}
line("3 geometry:")
describe(NSRange(location: longStart + 10, length: 4))            // visible part
describe(NSRange(location: longStart + limit - 3, length: 3))     // last visible characters
describe(NSRange(location: longStart + limit + 50, length: 4))    // hidden
describe(NSRange(location: longStart + longLength - 10, length: 4)) // end of the hidden part
describe(NSRange(location: longStart + longLength + 3, length: 4))  // the line after

// 4. scrolling to a hidden offset, selecting in it
let before = scroll.contentView.bounds.origin.y
let scrollMs = ms { textView.scrollRangeToVisible(NSRange(location: longStart + limit + 5000, length: 3)) }
line("4 scrollRangeToVisible(hidden): \(String(format: "%.1f", scrollMs)) ms; y \(Int(before)) → \(Int(scroll.contentView.bounds.origin.y)); long line occupies y \(Int(fragments.first { $0.start == longStart }.map { _ in layout.usageBoundsForTextContainer.minY } ?? 0))…")
textView.setSelectedRange(NSRange(location: longStart + limit + 100, length: 20))
line("  setSelectedRange(hidden 20): selectedRange \(textView.selectedRange()); textSelections \(layout.textSelections.count)")

// 5. copy
let pasteboard = NSPasteboard(name: NSPasteboard.Name("truncprobe.\(getpid())"))
@MainActor func copy(_ r: NSRange) -> String? {
    textView.setSelectedRange(r)
    pasteboard.clearContents()
    _ = textView.writeSelection(to: pasteboard, types: textView.writablePasteboardTypes)
    return pasteboard.string(forType: .string)
}
let across = NSRange(location: longStart + limit - 20, length: 60)
let copied = copy(across)
let expected = (textView.string as NSString).substring(with: across)
line("5 copy of a selection across the cut: \(copied == expected ? "equals the stored text" : "DIFFERS: \(String(describing: copied?.prefix(80)))")")
textView.selectAll(nil)
pasteboard.clearContents()
_ = textView.writeSelection(to: pasteboard, types: textView.writablePasteboardTypes)
line("  select all + copy: \(pasteboard.string(forType: .string) == text ? "whole document, byte for byte" : "DIFFERS (\(pasteboard.string(forType: .string)?.utf16.count ?? -1) vs \(text.utf16.count))")")
pasteboard.releaseGlobally()

// 6. caret movement through the cut
textView.setSelectedRange(NSRange(location: longStart + limit - 3, length: 0))
var trail: [Int] = []
for _ in 0..<8 { autoreleasepool { textView.moveRight(nil) }; trail.append(textView.selectedRange().location - longStart) }
line("6 moveRight from limit-3: caret offsets within the line: \(trail)")
textView.setSelectedRange(NSRange(location: longStart + 5, length: 0))
textView.moveToEndOfLine(nil)
line("  moveToEndOfLine from the start of the line: caret at \(textView.selectedRange().location - longStart) (line length \(longLength))")
textView.setSelectedRange(NSRange(location: longStart + 5, length: 0))
textView.moveToEndOfParagraph(nil)
line("  moveToEndOfParagraph: caret at \(textView.selectedRange().location - longStart)")
textView.moveDown(nil)
line("  then moveDown: caret at \(textView.selectedRange().location - longStart) (short line after begins at \(longLength + 1))")

// 6b. where does the caret go near the cut, in both directions
func steps(from start: Int, count: Int = 6, _ move: () -> Void) -> [Int] {
    textView.setSelectedRange(NSRange(location: longStart + start, length: 0))
    var trail: [Int] = []
    for _ in 0..<count { autoreleasepool { move() }; trail.append(textView.selectedRange().location - longStart) }
    return trail
}
line("6b caret trails (offsets within the long line; the next line starts at \(longLength + 1)):")
line("  moveRight from 10: \(steps(from: 10) { textView.moveRight(nil) })")
line("  moveRight from limit-12: \(steps(from: limit - 12, count: 14) { textView.moveRight(nil) })")
line("  moveLeft from the start of the next line: \(steps(from: longLength + 1, count: 4) { textView.moveLeft(nil) })")
line("  moveDown from limit-60 (last visible rows): \(steps(from: limit - 60, count: 4) { textView.moveDown(nil) })")
line("  moveWordRight from limit-15: \(steps(from: limit - 15, count: 4) { textView.moveWordRight(nil) })")
textView.setSelectedRange(NSRange(location: longStart + limit - 10, length: 0))
for _ in 0..<12 { autoreleasepool { textView.moveRightAndModifySelection(nil) } }
line("  shift+right x12 from limit-10: selection \(textView.selectedRange().location - longStart)+\(textView.selectedRange().length)")

// 7. hit testing
if let f = fragments.first(where: { $0.start == longStart }) {
    _ = f
    let origin = textView.textContainerOrigin
    var lastRowY: CGFloat = 0
    layout.enumerateTextLayoutFragments(from: layout.documentRange.location, options: []) { frag in
        if layout.offset(from: layout.documentRange.location, to: frag.rangeInElement.location) == longStart {
            lastRowY = frag.layoutFragmentFrame.minY + frag.layoutFragmentFrame.height - 4
            return false
        }
        return true
    }
    let atEnd = textView.characterIndexForInsertion(at: NSPoint(x: origin.x + 600, y: lastRowY + origin.y))
    let atStart = textView.characterIndexForInsertion(at: NSPoint(x: origin.x + 2, y: lastRowY + origin.y - 30))
    line("7 hit test, last row of the long line (right side): offset \(atEnd - longStart); a row above (left side): offset \(atStart - longStart)")
}

// 8. what the string and accessibility say
line("8 accessibilityNumberOfCharacters: \(textView.accessibilityNumberOfCharacters()) (storage \(text.utf16.count)); visibleCharacterRange \(textView.accessibilityVisibleCharacterRange())")
line("done")
