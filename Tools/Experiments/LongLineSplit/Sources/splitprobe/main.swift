import AppKit
import Foundation

func ms(_ body: () -> Void) -> Double {
    let clock = ContinuousClock()
    let d = clock.measure(body)
    return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
}

nonisolated(unsafe) var traceEnumeration = 0
nonisolated(unsafe) var enumBase = 0
nonisolated(unsafe) var enumRing: [String] = []
nonisolated(unsafe) var currentSplitter: AnyObject?

final class Piece: NSTextParagraph {
    nonisolated(unsafe) var content: NSTextRange?
    nonisolated(unsafe) var separator: NSTextRange?
    override var paragraphContentRange: NSTextRange? { content }
    override var paragraphSeparatorRange: NSTextRange? { separator }
}

/// Hands TextKit a long paragraph as several elements. The text storage is not touched.
final class SplittingContentStorage: NSTextContentStorage {
    nonisolated(unsafe) var limit = Int(ProcessInfo.processInfo.environment["PIECE"] ?? "") ?? 2048
    nonisolated(unsafe) var enumerations = 0
    nonisolated(unsafe) var splitParagraphs = 0
    nonisolated(unsafe) var piecesMade = 0
    nonisolated(unsafe) var log = false
    nonisolated(unsafe) var totalMs = 0.0
    nonisolated(unsafe) var splitMs = 0.0
    nonisolated(unsafe) var blockMs = 0.0
    nonisolated(unsafe) var superBuildMs = 0.0
    nonisolated(unsafe) var retained: [NSTextParagraph] = []
    nonisolated(unsafe) var cache: [String: [NSTextParagraph]] = [:]
    nonisolated(unsafe) var useCache = true
    nonisolated(unsafe) var lastParagraphCount = 1
    nonisolated(unsafe) var keepGenerations = Int(ProcessInfo.processInfo.environment["KEEP"] ?? "") ?? 3
    nonisolated(unsafe) var generations: [[NSTextParagraph]] = [[]]
    nonisolated(unsafe) var cacheHits = 0
    nonisolated(unsafe) var observer: NSObjectProtocol?

    func watchStorage() {
        guard let storage = textStorage else { return }
        observer = NotificationCenter.default.addObserver(forName: NSTextStorage.didProcessEditingNotification, object: storage, queue: nil) { [weak self] _ in
            guard let self else { return }
            if ProcessInfo.processInfo.environment["INVALIDATE"] != nil, let storage = self.textStorage {
                let count = (storage.string as NSString).components(separatedBy: "\n").count
                if count != self.lastParagraphCount {
                    self.lastParagraphCount = count
                    for manager in self.textLayoutManagers { manager.invalidateLayout(for: manager.documentRange) }
                }
            }
            self.cache.removeAll()
            if self.keepGenerations == 0 {
                self.retained.removeAll()
            } else {
                self.generations.append([])
                if self.generations.count > self.keepGenerations { self.generations.removeFirst() }
            }
        }
    }

    nonisolated(unsafe) var traceCalls = false
    nonisolated(unsafe) var callCounts: [String: Int] = [:]

    override func textElements(for range: NSTextRange) -> [NSTextElement] {
        callCounts["textElements(for:)", default: 0] += 1
        var result: [NSTextElement] = []
        _ = enumerateTextElements(from: range.location, options: []) { element in
            guard let r = element.elementRange else { return true }
            if r.location.compare(range.endLocation) != .orderedAscending { return false }
            result.append(element)
            return true
        }
        return result
    }

    override func attributedString(for textElement: NSTextElement) -> NSAttributedString? {
        callCounts["attributedString(for:)", default: 0] += 1
        if let piece = textElement as? Piece { return piece.attributedString }
        return super.attributedString(for: textElement)
    }

    /// Hands over the pieces that lie at or after `from` (or at or before it, in reverse), in order.
    private func emit(_ pieces: [NSTextParagraph], from textLocation: NSTextLocation?, paragraphStart: NSTextLocation, options: NSTextContentManager.EnumerationOptions, block: (NSTextElement) -> Bool, stoppedAt: inout NSTextLocation?, delivered: inout [String]) -> Bool {
        let reverse = options.contains(.reverse)
        var relative: Int? = nil
        if let textLocation { relative = offset(from: paragraphStart, to: textLocation) }
        var chosen = pieces
        if let relative {
            chosen = pieces.filter { piece in
                guard let r = piece.elementRange else { return true }
                let start = offset(from: paragraphStart, to: r.location)
                let end = offset(from: paragraphStart, to: r.endLocation)
                if reverse { return start < relative || (relative <= 0 && start == 0) }
                return end > relative || (piece === pieces.last && relative >= end)
            }
        }
        if reverse { chosen.reverse() }
        if traceEnumeration > 0 {
            let spans = chosen.compactMap { $0.elementRange.map { "\(offset(from: documentRange.location, to: $0.location))..\(offset(from: documentRange.location, to: $0.endLocation))" } }
            FileHandle.standardError.write(Data("  emit relative=\(String(describing: relative)) pieces=\(spans.prefix(4))...(\(spans.count))\n".utf8))
        }
        for piece in chosen {
            delivered.append(piece.elementRange.map { "\(offset(from: documentRange.location, to: $0.location))..\(offset(from: documentRange.location, to: $0.endLocation))" } ?? "nil")
            let blockStarted = ContinuousClock.now
            let keep = block(piece)
            blockMs += Self.since(blockStarted)
            if !keep {
                stoppedAt = reverse ? piece.elementRange?.location : piece.elementRange?.endLocation
                return false
            }
        }
        return true
    }

    static func since(_ start: ContinuousClock.Instant) -> Double {
        let d = start.duration(to: .now)
        return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }

    override func enumerateTextElements(
        from textLocation: NSTextLocation?, options: NSTextContentManager.EnumerationOptions = [],
        using block: (NSTextElement) -> Bool
    ) -> NSTextLocation? {
        enumerations += 1
        do {
            let from = textLocation.map { offset(from: documentRange.location, to: $0) }
            enumRing.append("from=\(String(describing: from)) reverse=\(options.contains(.reverse))")
            if enumRing.count > 10 { enumRing.removeFirst() }
            if enumerations - enumBase > 20_000 {
                FileHandle.standardError.write(Data("LOOP: more than 20000 enumerations in one frame. Last calls:\n  \(enumRing.joined(separator: "\n  "))\ndocument length \(textStorage?.length ?? -1), paragraphs \(textStorage?.string.components(separatedBy: "\n").map { $0.utf16.count } ?? [])\n".utf8))
                exit(3)
            }
        }
        if traceEnumeration > 0 {
            traceEnumeration += 1
            let from = textLocation.map { offset(from: documentRange.location, to: $0) }
            FileHandle.standardError.write(Data("ENUM #\(traceEnumeration) from=\(String(describing: from)) options=\(options.rawValue) reverse=\(options.contains(.reverse))\n".utf8))
            if traceEnumeration > 60 { exit(3) }
        }
        let started = ContinuousClock.now
        defer { totalMs += Self.since(started) }
        var delivered: [String] = []
        let origin = documentRange.location
        func note(_ element: NSTextElement) {
            delivered.append(element.elementRange.map { "\(offset(from: origin, to: $0.location))..\(offset(from: origin, to: $0.endLocation))" } ?? "nil")
        }
        var superStart = ContinuousClock.now
        var stoppedInsidePieces: NSTextLocation?
        let ended = super.enumerateTextElements(from: textLocation, options: options) { element in
            superBuildMs += Self.since(superStart)
            defer { superStart = ContinuousClock.now }
            guard let paragraph = element as? NSTextParagraph, let range = paragraph.elementRange else {
                note(element)
                return block(element)
            }
            let text = paragraph.attributedString
            guard text.length > limit else { note(element); return block(element) }
            splitParagraphs += 1
            if splitParagraphs == 1 {
                FileHandle.standardError.write(Data("original: elementRange=\(String(describing: paragraph.elementRange)) content=\(String(describing: paragraph.paragraphContentRange)) separator=\(String(describing: paragraph.paragraphSeparatorRange)) docRange=\(String(describing: documentRange))\n".utf8))
            }
            var pieces: [NSTextParagraph] = []
            let splitStarted = ContinuousClock.now
            defer { splitMs += Self.since(splitStarted) }
            let key = "\(offset(from: documentRange.location, to: range.location))-\(text.length)"
            if useCache, let hit = cache[key] {
                cacheHits += 1
                return emit(hit, from: textLocation, paragraphStart: range.location, options: options, block: block, stoppedAt: &stoppedInsidePieces, delivered: &delivered)
            }
            var start = 0
            while start < text.length {
                var end = min(start + limit, text.length)
                if end < text.length {
                    // Prefer to cut after a space so wrapping looks natural.
                    let s = text.string as NSString
                    var probe = end
                    while probe > start + limit / 2, s.character(at: probe - 1) != 0x20 { probe -= 1 }
                    if probe > start + limit / 2 {
                        end = probe
                    } else {
                        // No space to cut after: cut at a character boundary, never inside a pair or cluster.
                        let sequence = s.rangeOfComposedCharacterSequence(at: end)
                        if sequence.location > start { end = sequence.location } else { end = sequence.location + sequence.length }
                    }
                }
                let piece = Piece(attributedString: text.attributedSubstring(from: NSRange(location: start, length: end - start)))
                let from = location(range.location, offsetBy: start)
                let to = location(range.location, offsetBy: end)
                if log || piecesMade < 3 {
                    FileHandle.standardError.write(Data("piece \(start)..<\(end) from=\(String(describing: from)) to=\(String(describing: to)) manager=\(String(describing: paragraph.textContentManager === self)) origRange=\(range)\n".utf8))
                }
                if let from, let to {
                    piece.elementRange = NSTextRange(location: from, end: to)
                    // The original's own content/separator split: only the last piece has a real separator.
                    let isLast = end == text.length
                    if isLast, let contentRange = paragraph.paragraphContentRange {
                        piece.content = NSTextRange(location: from, end: contentRange.endLocation)
                        piece.separator = paragraph.paragraphSeparatorRange
                    } else {
                        piece.content = NSTextRange(location: from, end: to)
                        piece.separator = NSTextRange(location: to, end: to)
                    }
                }
                piece.textContentManager = self
                pieces.append(piece)
                start = end
            }
            piecesMade += pieces.count
            if keepGenerations == 0 { retained.append(contentsOf: pieces) } else { generations[generations.count - 1].append(contentsOf: pieces) }
            if useCache { cache[key] = pieces }
            if log { FileHandle.standardError.write(Data("split \(text.length) into \(pieces.count)\n".utf8)) }
            return emit(pieces, from: textLocation, paragraphStart: range.location, options: options, block: block, stoppedAt: &stoppedInsidePieces, delivered: &delivered)
        }
        // Where the enumeration ended is part of the answer: when the caller stopped inside a split
        // paragraph it is the edge of that piece, not the end of the whole paragraph that `super` knows.
        let result = stoppedInsidePieces ?? ended
        if enumRing.count > 0 {
            enumRing[enumRing.count - 1] += " delivered=\(delivered.prefix(6)) returned=\(String(describing: result.map { offset(from: origin, to: $0) }))"
        }
        return result
    }
}

/// Lays a long paragraph out in parts: a layout fragment may cover only a range inside its element.
final class FragmentSplitter: NSObject, NSTextLayoutManagerDelegate {
    nonisolated(unsafe) var limit = Int(ProcessInfo.processInfo.environment["PIECE"] ?? "") ?? 2048
    nonisolated(unsafe) var calls = 0
    nonisolated(unsafe) var split = 0
    nonisolated(unsafe) var log = false

    /// Boundary k: the first position at or after k*limit that follows a space.
    static func boundary(_ k: Int, in text: NSString, limit: Int) -> Int {
        if k <= 0 { return 0 }
        let target = k * limit
        if target >= text.length { return text.length }
        var p = target
        while p < text.length, text.character(at: p - 1) != 0x20, p < target + limit / 2 { p += 1 }
        return p
    }

    func textLayoutManager(_ textLayoutManager: NSTextLayoutManager, textLayoutFragmentFor location: NSTextLocation, in textElement: NSTextElement) -> NSTextLayoutFragment {
        calls += 1
        guard let paragraph = textElement as? NSTextParagraph, let elementRange = paragraph.elementRange,
              paragraph.attributedString.length > limit, let content = textLayoutManager.textContentManager else {
            return NSTextLayoutFragment(textElement: textElement, range: textElement.elementRange)
        }
        split += 1
        let text = paragraph.attributedString.string as NSString
        let relative = content.offset(from: elementRange.location, to: location)
        var k = max(0, relative / limit)
        if relative < Self.boundary(k, in: text, limit: limit) { k -= 1 }
        let start = Self.boundary(k, in: text, limit: limit)
        let end = Self.boundary(k + 1, in: text, limit: limit)
        if log { FileHandle.standardError.write(Data("fragment for rel=\(relative): piece \(k) \(start)..<\(end)\n".utf8)) }
        guard let from = content.location(elementRange.location, offsetBy: start),
              let to = content.location(elementRange.location, offsetBy: end),
              let range = NSTextRange(location: from, end: to) else {
            return NSTextLayoutFragment(textElement: textElement, range: textElement.elementRange)
        }
        return NSTextLayoutFragment(textElement: textElement, range: range)
    }
}
nonisolated(unsafe) let fragmentSplitter = FragmentSplitter()

struct Stack {
    let textView: NSTextView
    let scroll: NSScrollView
    let window: NSWindow
    let content: NSTextContentStorage
    let layout: NSTextLayoutManager
    let storage: NSTextStorage
}

@MainActor
func makeStack(text: String, split: Bool) -> Stack {
    let storage = NSTextStorage(string: text, attributes: [.foregroundColor: NSColor.textColor])
    let mode = ProcessInfo.processInfo.environment["MODE"] ?? "storage"
    let content: NSTextContentStorage = split && mode == "storage" ? SplittingContentStorage() : NSTextContentStorage()
    let layout = NSTextLayoutManager()
    content.textStorage = storage
    (content as? SplittingContentStorage)?.watchStorage()
    currentSplitter = content
    content.addTextLayoutManager(layout)
    if split && mode == "fragment" { layout.delegate = fragmentSplitter }
    layout.textContainer = NSTextContainer(size: NSSize(width: 800, height: CGFloat.greatestFiniteMagnitude))
    layout.textContainer!.widthTracksTextView = true
    let textView = NSTextView(frame: .zero, textContainer: layout.textContainer!)
    textView.isRichText = false
    textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
    textView.textContainerInset = NSSize(width: 6, height: 6)
    textView.isHorizontallyResizable = false
    textView.isVerticallyResizable = true
    textView.minSize = .zero
    textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    textView.autoresizingMask = [.width]
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 900, height: 640))
    scroll.hasVerticalScroller = true
    textView.frame = NSRect(x: 0, y: 0, width: 900, height: 640)
    scroll.documentView = textView
    let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 900, height: 640), styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: .aqua)
    window.contentView = scroll
    return Stack(textView: textView, scroll: scroll, window: window, content: content, layout: layout, storage: storage)
}

var canvas: NSBitmapImageRep?
@MainActor
func present(_ view: NSView) {
    if let s = currentSplitter as? SplittingContentStorage { enumBase = s.enumerations }
    view.layoutSubtreeIfNeeded()
    if canvas == nil || canvas!.size != view.bounds.size { canvas = view.bitmapImageRepForCachingDisplay(in: view.bounds) }
    if let canvas { view.cacheDisplay(in: view.bounds, to: canvas) }
}

@MainActor
func stats(_ xs: [Double]) -> String {
    let s = xs.sorted()
    guard !s.isEmpty else { return "n=0" }
    func p(_ q: Double) -> Double { s[min(s.count - 1, max(0, Int((Double(s.count) * q).rounded(.up)) - 1))] }
    return String(format: "n=%d p50=%.2f p95=%.2f max=%.2f", s.count, p(0.5), p(0.95), s.last!)
}

@MainActor
func run(kb: Int, split: Bool, shot: String?) {
    let unit = "word поток 😀 value, "
    var text = ""
    let wrapAt = Int(ProcessInfo.processInfo.environment["LINE_CHARS"] ?? "") ?? 0
    var lineLength = 0
    while text.utf8.count < kb * 1024 {
        text += unit
        lineLength += unit.utf16.count
        if wrapAt > 0, lineLength >= wrapAt { text += "\n"; lineLength = 0 }
    }
    let stack = makeStack(text: text, split: split)
    let tv = stack.textView
    var first = 0.0
    first = ms {
        stack.window.orderFrontRegardless()
        present(stack.scroll)
    }
    let total = tv.string.utf16.count
    var typing: [Double] = []
    let middle = total / 2
    tv.setSelectedRange(NSRange(location: middle, length: 0))
    tv.scrollRangeToVisible(NSRange(location: middle, length: 0))
    present(stack.scroll)
    var position = middle
    for _ in 0..<30 {
        autoreleasepool {
            typing.append(ms {
                tv.insertText("x", replacementRange: NSRange(location: position, length: 0))
                present(stack.scroll)
            })
            position += 1
        }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.0005))
    }
    func save(_ suffix: String) {
        if let shot, let canvas, let png = canvas.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: shot + suffix + ".png"))
        }
    }
    save("-typed")
    var scrollEnd = 0.0
    tv.setSelectedRange(NSRange(location: tv.string.utf16.count, length: 0))
    scrollEnd = ms {
        tv.scrollRangeToVisible(NSRange(location: tv.string.utf16.count, length: 0))
        present(stack.scroll)
    }
    save("-end")
    print("geometry: textView.frame=\(tv.frame) clip.bounds=\(stack.scroll.contentView.bounds) container.size=\(String(describing: tv.textContainer?.size)) viewport=\(String(describing: stack.layout.textViewportLayoutController.viewportRange)) viewportBounds=\(stack.layout.textViewportLayoutController.viewportBounds)")
    var viewportFragments = 0
    if let viewport = stack.layout.textViewportLayoutController.viewportRange {
        stack.layout.enumerateTextLayoutFragments(from: viewport.location, options: []) { fragment in
            if fragment.rangeInElement.location.compare(viewport.endLocation) != .orderedAscending { return false }
            viewportFragments += 1
            return true
        }
    }
    var extra = ""
    if split, (ProcessInfo.processInfo.environment["MODE"] ?? "storage") == "fragment" {
        extra = " delegateCalls=\(fragmentSplitter.calls) splitCalls=\(fragmentSplitter.split)"
    }
    if let s = stack.content as? SplittingContentStorage {
        extra = " totalMs=\(Int(s.totalMs)) superBuildMs=\(Int(s.superBuildMs)) splitMs=\(Int(s.splitMs)) blockMs=\(Int(s.blockMs)) cacheHits=\(s.cacheHits) enumerations=\(s.enumerations) splitParagraphs=\(s.splitParagraphs) pieces=\(s.piecesMade)"
    }
    print("kb=\(kb) split=\(split) firstLayout=\(String(format: "%.1f", first))ms typing[\(stats(typing))] scrollEnd=\(String(format: "%.1f", scrollEnd))ms viewportFragments=\(viewportFragments) len=\(tv.string.utf16.count)\(extra)")
}

NSApplication.shared.setActivationPolicy(.prohibited)
NSApp.finishLaunching()
let args = CommandLine.arguments
let kb = args.count > 1 ? Int(args[1]) ?? 50 : 50
let split = args.count > 2 ? args[2] == "1" : false
let shot = args.count > 3 ? args[3] : nil
if args.count <= 1 || (args[1] != "behave" && args[1] != "nav" && args[1] != "diff" && args[1] != "stress") { run(kb: kb, split: split, shot: shot) }

// MARK: Behaviour checks (mode: behave)

@MainActor
func boundaries(of stack: Stack) -> [Int] {
    var result: [Int] = []
    let content = stack.content
    _ = content.enumerateTextElements(from: content.documentRange.location, options: []) { element in
        if let range = element.elementRange {
            result.append(content.offset(from: content.documentRange.location, to: range.location))
        }
        return true
    }
    return result
}

@MainActor
func behave(split: Bool, hardCuts: Bool) -> [String] {
    var out: [String] = []
    let unit = hardCuts ? "abcdefghij😀klmnopqrstuvwxyzабвгд" : "word поток 😀 value, "
    var text = ""
    while text.utf16.count < 6000 { text += unit }
    let stack = makeStack(text: text, split: split)
    let tv = stack.textView
    stack.window.orderFrontRegardless()
    present(stack.scroll)
    let bounds = boundaries(of: stack)
    out.append("pieces=\(bounds.count) firstBoundaries=\(bounds.prefix(4)) height=\(Int(tv.frame.height))")
    let tlm = stack.layout

    // 1. moveRight across everything: selection must advance by one grapheme each time.
    tv.setSelectedRange(NSRange(location: 0, length: 0))
    var rights: [Int] = [0]
    for _ in 0..<2000 {
        tv.moveRight(nil)
        rights.append(tv.selectedRange().location)
        if rights.last! == tv.string.utf16.count { break }
    }
    var stuck = 0
    for i in 1..<rights.count where rights[i] <= rights[i - 1] {
        stuck += 1
        if ProcessInfo.processInfo.environment["DEBUG"] != nil { print("  moveRight stuck at step \(i): \(rights[max(0, i - 3)...min(rights.count - 1, i + 3)])") }
    }
    out.append("moveRight steps=\(rights.count - 1) reachedEnd=\(rights.last! == text.utf16.count) stuck=\(stuck) checksum=\(rights.reduce(0, &+))")

    // 2. moveLeft back to the start.
    var lefts = 0
    for _ in 0..<2100 {
        let before = tv.selectedRange().location
        tv.moveLeft(nil)
        if tv.selectedRange().location >= before { break }
        lefts += 1
        if tv.selectedRange().location == 0 { break }
    }
    out.append("moveLeft steps=\(lefts) atStart=\(tv.selectedRange().location == 0)")

    // 3. moveDown / moveUp: must progress and not jump to the ends.
    tv.setSelectedRange(NSRange(location: 0, length: 0))
    var downs: [Int] = [0]
    for _ in 0..<80 {
        tv.moveDown(nil)
        downs.append(tv.selectedRange().location)
    }
    var downStuck = 0, downBackward = 0
    for i in 1..<downs.count { if downs[i] == downs[i - 1] { downStuck += 1 }; if downs[i] < downs[i - 1] { downBackward += 1 } }
    out.append("moveDown x80 last=\(downs.last!) stuck=\(downStuck) backward=\(downBackward) first8=\(downs.prefix(8))")
    var ups: [Int] = []
    for _ in 0..<80 { tv.moveUp(nil); ups.append(tv.selectedRange().location) }
    out.append("moveUp x80 last=\(ups.last!) first4=\(ups.prefix(4))")

    // 4. Geometry of the caret and hit testing, over many offsets, boundaries included.
    var segmentFailures = 0, hitMismatch = 0, checked = 0, outOfOrder = 0
    var previousY = -CGFloat.infinity
    var samples = Array(stride(from: 0, to: text.utf16.count, by: 29))
    samples += bounds.dropFirst().flatMap { [$0 - 1, $0, $0 + 1] }
    samples = Array(Set(samples.filter { $0 >= 0 && $0 < text.utf16.count })).sorted()
    for offset in samples {
        guard let start = tlm.textContentManager?.location(tlm.documentRange.location, offsetBy: offset),
              let end = tlm.textContentManager?.location(start, offsetBy: 0),
              let range = NSTextRange(location: start, end: end) else { segmentFailures += 1; continue }
        // A real click can only land where the text is on screen, so bring the offset into view first.
        tv.scrollRangeToVisible(NSRange(location: offset, length: 0))
        present(stack.scroll)
        var frame: CGRect?
        tlm.enumerateTextSegments(in: range, type: .standard, options: [.rangeNotRequired]) { _, rect, _, _ in frame = rect; return false }
        guard let frame, frame.height > 0, frame.minX.isFinite else { segmentFailures += 1; continue }
        checked += 1
        if frame.minY + 0.5 < previousY { outOfOrder += 1 }
        previousY = frame.minY
        let point = NSPoint(x: frame.minX + tv.textContainerOrigin.x + 1, y: frame.midY + tv.textContainerOrigin.y)
        let hit = tv.characterIndexForInsertion(at: point)
        if abs(hit - offset) > 1 {
            hitMismatch += 1
            if ProcessInfo.processInfo.environment["DEBUG"] != nil { print("  hit mismatch offset=\(offset) hit=\(hit) frame=\(frame) nearBoundary=\(bounds.contains { abs($0 - offset) <= 1 })") }
        }
    }
    out.append("caret geometry checked=\(checked) segmentFailures=\(segmentFailures) outOfOrder=\(outOfOrder) hitTestMismatch=\(hitMismatch)")

    // 5. Edits across boundaries.
    var model = text as NSString
    func apply(_ range: NSRange, _ replacement: String) {
        tv.setSelectedRange(range)
        tv.insertText(replacement, replacementRange: range)
        model = model.replacingCharacters(in: range, with: replacement) as NSString
    }
    let b1 = bounds.count > 3 ? bounds[2] : 500
    apply(NSRange(location: b1 - 5, length: 11), "REPLACED")      // across a boundary
    apply(NSRange(location: b1, length: 0), "XYZ")                 // exactly at a boundary
    apply(NSRange(location: 100, length: 3000), "")                // delete a big stretch spanning many boundaries
    apply(NSRange(location: 50, length: 0), "tail\nnew line\n")    // insert newlines into the long line
    out.append("text matches model after edits: \(tv.string == model as String) len=\(tv.string.utf16.count)")
    present(stack.scroll)

    // 6. Keys that act on the paragraph.
    tv.setSelectedRange(NSRange(location: 2500, length: 0))
    tv.moveToBeginningOfParagraph(nil)
    let paraStart = tv.selectedRange().location
    tv.setSelectedRange(NSRange(location: 2500, length: 0))
    tv.moveToEndOfParagraph(nil)
    let paraEnd = tv.selectedRange().location
    tv.setSelectedRange(NSRange(location: 2500, length: 0))
    tv.moveToBeginningOfLine(nil)
    let lineStart = tv.selectedRange().location
    tv.setSelectedRange(NSRange(location: 2500, length: 0))
    tv.moveToEndOfLine(nil)
    let lineEnd = tv.selectedRange().location
    out.append("paragraph start=\(paraStart) end=\(paraEnd); visual line start=\(lineStart) end=\(lineEnd)")

    // 7. Word selection at boundaries.
    var wordResults: [String] = []
    for b in bounds.dropFirst().prefix(3) {
        tv.setSelectedRange(NSRange(location: min(b, tv.string.utf16.count), length: 0))
        tv.selectWord(nil)
        wordResults.append("\(tv.selectedRange())")
    }
    out.append("selectWord at boundaries: \(wordResults)")

    // 8. Undo of typing at a boundary.
    let before = tv.string
    tv.setSelectedRange(NSRange(location: 1000, length: 0))
    tv.insertText("Q", replacementRange: NSRange(location: 1000, length: 0))
    let typed = tv.string
    tv.undoManager?.undo()
    out.append("undo restores: \(tv.string == before) (typed changed: \(typed != before))")

    // 9. Marked text (input method) inside a piece and at a boundary.
    for (label, position) in [("middle of piece", 1100), ("at boundary", bounds.count > 5 ? bounds[5] : 1280)] {
        tv.setSelectedRange(NSRange(location: position, length: 0))
        let lengthBefore = tv.string.utf16.count
        tv.setMarkedText("あい", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        let hasMarked = tv.hasMarkedText()
        let markedRange = tv.markedRange()
        tv.setMarkedText("あいう", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        present(stack.scroll)
        tv.unmarkText()
        out.append("marked text \(label): hasMarked=\(hasMarked) range=\(markedRange) grewBy=\(tv.string.utf16.count - lengthBefore) afterUnmark=\(tv.hasMarkedText())")
    }

    // 10. scrollRangeToVisible to places far from the viewport.
    var notVisible = 0
    for offset in stride(from: 0, to: tv.string.utf16.count, by: 700) {
        tv.setSelectedRange(NSRange(location: offset, length: 0))
        tv.scrollRangeToVisible(NSRange(location: offset, length: 0))
        present(stack.scroll)
        let rect = tv.firstRect(forCharacterRange: NSRange(location: offset, length: 0), actualRange: nil)
        let inWindow = tv.window.map { $0.convertFromScreen(rect) } ?? .zero
        let local = tv.convert(inWindow, from: nil)
        if !tv.visibleRect.intersects(local) { notVisible += 1 }
    }
    out.append("scroll-to-offset notVisible=\(notVisible)")
    return out
}

if args.count > 1, args[1] == "behave" {
    let hard = args.count > 3 && args[3] == "hard"
    for line in behave(split: args.count > 2 && args[2] == "1", hardCuts: hard) { print(line) }
}

// MARK: Navigation inside later pieces (mode: nav)
@MainActor
func nav() {
    let unit = "word поток 😀 value, "
    var text = ""
    while text.utf16.count < 6000 { text += unit }
    let stack = makeStack(text: text, split: true)
    let tv = stack.textView
    stack.window.orderFrontRegardless()
    present(stack.scroll)
    let bounds = boundaries(of: stack)
    print("boundaries first: \(bounds.prefix(5))")
    func run(_ name: String, from: Int, length: Int = 0, _ action: () -> Void) {
        tv.setSelectedRange(NSRange(location: from, length: length))
        tv.scrollRangeToVisible(NSRange(location: from, length: 0))
        present(stack.scroll)
        action()
        print("\(name) from \(from)+\(length): -> \(tv.selectedRange())")
    }
    for from in [10, 300, 600, 1000, bounds[3] - 1, bounds[3], bounds[3] + 1] {
        run("moveRight", from: from) { tv.moveRight(nil) }
        run("moveLeft", from: from) { tv.moveLeft(nil) }
        run("moveRightAndModifySelection", from: from) { tv.moveRightAndModifySelection(nil) }
        run("moveWordRight", from: from) { tv.moveWordRight(nil) }
        run("deleteBackward", from: from) {
            let before = tv.string
            tv.deleteBackward(nil)
            print("   deleted length=\(before.utf16.count - tv.string.utf16.count)")
            tv.undoManager?.removeAllActions()
            // restore text for the next probe
            tv.string = before
            present(stack.scroll)
        }
    }
}

if args.count > 1, args[1] == "nav" { nav() }

// MARK: Differential command test (mode: diff)

@MainActor
func diffTest(hard: Bool, mixed: Bool) {
    let unit = hard ? "abcdefghij😀klmnopqrstuvwxyzабвгд" : "word поток 😀 value, "
    var long = ""
    while long.utf16.count < 3000 { long += unit }
    let text = mixed ? "first line\nsecond line\n" + long + "\nthird line\nfourth\n" : long
    let longStart = mixed ? "first line\nsecond line\n".utf16.count : 0
    func fresh(split: Bool) -> Stack {
        let stack = makeStack(text: text, split: split)
        stack.window.orderFrontRegardless()
        present(stack.scroll)
        return stack
    }
    let probe = fresh(split: true)
    let cuts = boundaries(of: probe)
    // Offsets near every piece boundary inside the long line, a few mid-piece ones, and the line's ends.
    var offsets = Set<Int>()
    for b in cuts where b > 0 { for d in -2...2 { offsets.insert(b + d) } }
    offsets.formUnion([longStart, longStart + 1, longStart + 500, longStart + long.utf16.count - 1, longStart + long.utf16.count])
    let sorted = offsets.filter { $0 >= 0 && $0 <= text.utf16.count }.sorted()
    let commands: [(String, Selector)] = [
        ("moveLeft", #selector(NSResponder.moveLeft(_:))), ("moveRight", #selector(NSResponder.moveRight(_:))),
        ("moveWordLeft", #selector(NSResponder.moveWordLeft(_:))), ("moveWordRight", #selector(NSResponder.moveWordRight(_:))),
        ("moveLeftAndModifySelection", #selector(NSResponder.moveLeftAndModifySelection(_:))),
        ("moveRightAndModifySelection", #selector(NSResponder.moveRightAndModifySelection(_:))),
        ("moveWordLeftAndModifySelection", #selector(NSResponder.moveWordLeftAndModifySelection(_:))),
        ("moveWordRightAndModifySelection", #selector(NSResponder.moveWordRightAndModifySelection(_:))),
        ("deleteBackward", #selector(NSResponder.deleteBackward(_:))), ("deleteForward", #selector(NSResponder.deleteForward(_:))),
        ("deleteWordBackward", #selector(NSResponder.deleteWordBackward(_:))), ("deleteWordForward", #selector(NSResponder.deleteWordForward(_:))),
        ("selectWord", #selector(NSResponder.selectWord(_:))),
        ("moveToBeginningOfParagraph", #selector(NSResponder.moveToBeginningOfParagraph(_:))),
        ("moveToEndOfParagraph", #selector(NSResponder.moveToEndOfParagraph(_:))),
        ("selectParagraph", #selector(NSResponder.selectParagraph(_:))),
        ("deleteToBeginningOfParagraph", #selector(NSResponder.deleteToBeginningOfParagraph(_:))),
        ("deleteToEndOfParagraph", #selector(NSResponder.deleteToEndOfParagraph(_:))),
        ("moveParagraphForwardAndModifySelection", #selector(NSResponder.moveParagraphForwardAndModifySelection(_:))),
        ("moveParagraphBackwardAndModifySelection", #selector(NSResponder.moveParagraphBackwardAndModifySelection(_:))),
        ("moveToBeginningOfDocument", #selector(NSResponder.moveToBeginningOfDocument(_:))),
        ("moveToEndOfDocument", #selector(NSResponder.moveToEndOfDocument(_:))),
        ("moveDown", #selector(NSResponder.moveDown(_:))), ("moveUp", #selector(NSResponder.moveUp(_:))),
        ("moveToBeginningOfLine", #selector(NSResponder.moveToBeginningOfLine(_:))), ("moveToEndOfLine", #selector(NSResponder.moveToEndOfLine(_:)))
    ]
    var differences: [String: [String]] = [:]
    var totals: [String: Int] = [:]
    for (name, selector) in commands {
        for offset in sorted {
            var results: [String] = []
            for split in [false, true] {
                let stack = fresh(split: split)
                let tv = stack.textView
                tv.setSelectedRange(NSRange(location: offset, length: 0))
                tv.scrollRangeToVisible(NSRange(location: offset, length: 0))
                present(stack.scroll)
                NSApp.sendAction(selector, to: tv, from: nil)
                results.append("\(tv.selectedRange())|\(tv.string.utf16.count)")
            }
            totals[name, default: 0] += 1
            if results[0] != results[1] { differences[name, default: []].append("@\(offset): plain=\(results[0]) split=\(results[1])") }
        }
    }
    print("long line starts at \(longStart), \(cuts.count) elements, \(sorted.count) start offsets, \(commands.count) commands")
    for (name, _) in commands {
        let d = differences[name] ?? []
        print(d.isEmpty ? "  same      \(name)" : "  DIFFERS   \(name): \(d.count)/\(totals[name] ?? 0)  e.g. \(d.prefix(2).joined(separator: "; "))")
    }
}

if args.count > 1, args[1] == "diff" {
    diffTest(hard: args.count > 2 && args[2] == "hard", mixed: args.count > 3 && args[3] == "mixed")
}

// MARK: Stress (mode: stress)

struct SplitMix { var state: UInt64
    mutating func next() -> UInt64 { state &+= 0x9E3779B97F4A7C15; var z = state; z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9; z = (z ^ (z >> 27)) &* 0x94D049BB133111EB; return z ^ (z >> 31) }
    mutating func below(_ n: Int) -> Int { n <= 0 ? 0 : Int(next() % UInt64(n)) }
}

@MainActor
func stress(seed: UInt64, operations: Int) {
    var rng = SplitMix(state: seed)
    let unit = "word поток 😀 value, "
    var text = ""
    while text.utf16.count < 20_000 { text += unit }
    let stack = makeStack(text: text, split: ProcessInfo.processInfo.environment["PLAIN"] == nil)
    let tv = stack.textView
    stack.window.orderFrontRegardless()
    present(stack.scroll)
    var model = NSMutableString(string: text)
    var done = 0
    for step in 0..<operations {
        autoreleasepool {
            let length = tv.string.utf16.count
            let which = rng.below(9)
            if ProcessInfo.processInfo.environment["TRACE"] != nil {
                var info = mach_task_basic_info(); var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / 4)
                _ = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: 1) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) } }
                FileHandle.standardError.write(Data("TRACE step=\(step) op=\(which) length=\(length) rssMB=\(info.resident_size / 1_048_576)\n".utf8))
            }
            switch which {
            case 0, 1:
                let at = rng.below(length + 1)
                let s = ["x", "ab", "é", "😀", " ", "word ", String(repeating: "grow ", count: 30), String(repeating: "поток 😀 ", count: 20)][rng.below(8)]
                tv.setSelectedRange(NSRange(location: at, length: 0))
                tv.insertText(s, replacementRange: NSRange(location: at, length: 0))
                model.replaceCharacters(in: NSRange(location: at, length: 0), with: s)
            case 2:
                let at = rng.below(length)
                let len = min(rng.below(200), length - at)
                // keep the range off a surrogate pair
                var range = NSRange(location: at, length: len)
                range = (model as NSString).rangeOfComposedCharacterSequences(for: range)
                tv.insertText("", replacementRange: range)
                model.replaceCharacters(in: range, with: "")
            case 3 where ProcessInfo.processInfo.environment["NONEWLINE"] == nil:
                let at = rng.below(length + 1)
                tv.insertText("\n", replacementRange: NSRange(location: at, length: 0))
                model.replaceCharacters(in: NSRange(location: at, length: 0), with: "\n")
            case 4 where ProcessInfo.processInfo.environment["NONEWLINE"] == nil:
                let range = (model as NSString).range(of: "\n")
                if range.location != NSNotFound {
                    tv.insertText("", replacementRange: range)
                    model.replaceCharacters(in: range, with: "")
                }
            case 5:
                tv.scrollRangeToVisible(NSRange(location: rng.below(length), length: 0))
            case 6:
                let from = rng.below(length)
                tv.setSelectedRange(NSRange(location: from, length: 0))
                let moves = rng.below(5)
                var plan: [String] = []
                for _ in 0..<moves {
                    let down = rng.below(2) == 0
                    plan.append(down ? "down" : "up")
                    if ProcessInfo.processInfo.environment["DUMP_AT"] == "\(step)" {
                        let lengths = tv.string.components(separatedBy: "\n").map { $0.utf16.count }
                        FileHandle.standardError.write(Data("DUMP step=\(step) from=\(from) plan=\(plan) paragraphs=\(lengths) elements=\(boundaries(of: stack))\n".utf8))
                    }
                    down ? tv.moveDown(nil) : tv.moveUp(nil)
                    if ProcessInfo.processInfo.environment["DUMP_AT"] == "\(step)", plan.count == 3 { traceEnumeration = 1 }
                    if ProcessInfo.processInfo.environment["DUMP_AT"] == "\(step)" {
                        FileHandle.standardError.write(Data("DUMP after move selection=\(tv.selectedRange())\n".utf8))
                    }
                }
            case 7:
                let at = rng.below(length)
                tv.setSelectedRange(NSRange(location: at, length: 0))
                tv.setMarkedText("あい", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
                present(stack.scroll)
                let marked = tv.markedRange()
                tv.unmarkText()
                _ = marked
                model = NSMutableString(string: tv.string)   // marked text enters the document: re-sync the model
            default:
                tv.setSelectedRange(NSRange(location: rng.below(length), length: min(rng.below(900), 300)))
                tv.moveRightAndModifySelection(nil)
            }
            present(stack.scroll)
            done = step + 1
        }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.0002))
    }
    let same = tv.string == model as String
    var extra = ""
    if let s = stack.content as? SplittingContentStorage { extra = " pieces=\(s.piecesMade) cacheHits=\(s.cacheHits) elements=\(boundaries(of: stack).count) keep=\(s.keepGenerations)" }
    print("stress seed=\(seed) operations=\(done) textMatchesModel=\(same) length=\(tv.string.utf16.count)\(extra)")
}

if args.count > 1, args[1] == "stress" {
    stress(seed: UInt64(args.count > 2 ? Int(args[2]) ?? 1 : 1), operations: args.count > 3 ? Int(args[3]) ?? 2000 : 2000)
}
