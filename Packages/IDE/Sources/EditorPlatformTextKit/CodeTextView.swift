import AppKit

/// Edit-menu commands the code view answers through the responder chain.
@MainActor @objc public protocol CodeLineActions {
    func duplicateLine(_ sender: Any?)

    func toggleLineComment(_ sender: Any?)
}

final class CodeTextView: NSTextView, CodeLineActions {
    weak var bridge: NativeEditingBridge?
    var hooks: EditorInputHooks?

    override func keyDown(with event: NSEvent) {
        // Marked text belongs to the input method, whatever the key is.
        if let hooks, !hasMarkedText() {
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([
                .capsLock,
                .numericPad,
                .function
            ])
            if modifiers == .control, event.charactersIgnoringModifiers == " ", let request = hooks.requestCompletion {
                return request()
            }

            if modifiers == [.control, .shift], event.charactersIgnoringModifiers == " ",
               let request = hooks.requestHover {
                return request()
            }

            hooks.interactionBegan?()

            if hooks.interceptKey?(event) == true { return }
        }

        super.keyDown(with: event)
    }

    // MARK: Whitespace marks

    /// Which blanks are marked: tabs with an arrow, spaces with a small dot. Presentation only.
    var whitespaceMarks = (tabs: false, spaces: false) {
        didSet { if whitespaceMarks != oldValue { needsDisplay = true } }
    }

    struct WhitespaceMark: Equatable {
        enum Kind { case tab, space }

        let offset: Int
        let kind: Kind
        /// The cell of the character in this view's coordinates, and the line's baseline height.
        let frame: NSRect
        let baseline: CGFloat
    }

    /// The marks to draw: every tab and space of the laid-out viewport. A run of spaces is looked
    /// up in one go and shared out by character, so indentation costs a call per run.
    func visibleWhitespaceMarks() -> [WhitespaceMark] {
        guard whitespaceMarks.tabs || whitespaceMarks.spaces, let manager = textLayoutManager,
              let content = manager.textContentManager, let range = manager.textViewportLayoutController.viewportRange,
              let storage = textStorage else { return [] }

        let start = content.offset(from: content.documentRange.location, to: range.location)
        let length = content.offset(from: range.location, to: range.endLocation)
        guard length > 0, length <= 200_000, start + length <= storage.length else { return [] }

        let text = storage.mutableString
        let origin = textContainerOrigin
        var marks: [WhitespaceMark] = []

        func add(_ kind: WhitespaceMark.Kind, from first: Int, to end: Int) {
            guard let from = content.location(content.documentRange.location, offsetBy: first),
                  let to = content.location(content.documentRange.location, offsetBy: end),
                  let segmentRange = NSTextRange(location: from, end: to) else { return }

            manager.enumerateTextSegments(in: segmentRange, type: .standard, options: []) { part, frame, baseline, _ in
                guard let part else { return true }

                let low = content.offset(from: content.documentRange.location, to: part.location)
                let high = content.offset(from: content.documentRange.location, to: part.endLocation)
                let count = max(1, high - low)
                let cell = frame.width / CGFloat(count)
                for index in 0..<count {
                    marks.append(WhitespaceMark(
                        offset: low + index,
                        kind: kind,
                        frame: NSRect(
                            x: frame.minX + origin.x + cell * CGFloat(index),
                            y: frame.minY + origin.y,
                            width: cell,
                            height: frame.height
                        ),
                        baseline: frame.minY + origin.y + baseline
                    ))
                }

                return true
            }
        }

        var index = start
        let end = start + length
        while index < end {
            let unit = text.character(at: index)
            if unit == 0x09, whitespaceMarks.tabs {
                add(.tab, from: index, to: index + 1)
                index += 1
            } else if unit == 0x20, whitespaceMarks.spaces {
                var run = index + 1
                while run < end, text.character(at: run) == 0x20 { run += 1 }

                add(.space, from: index, to: run)
                index = run
            } else {
                index += 1
            }
        }

        return marks
    }

    private func drawWhitespaceMarks(in dirtyRect: NSRect) {
        let marks = visibleWhitespaceMarks().filter { $0.frame.intersects(dirtyRect) }
        guard !marks.isEmpty else { return }

        NSColor.secondaryLabelColor.withAlphaComponent(0.5).set()
        let xHeight = (font ?? .monospacedSystemFont(ofSize: 13, weight: .regular)).xHeight
        for mark in marks {
            let middle = mark.baseline - xHeight / 2
            switch mark.kind {
            case .space:
                NSBezierPath(ovalIn: NSRect(x: mark.frame.midX - 0.9, y: middle - 0.9, width: 1.8, height: 1.8)).fill()
            case .tab:
                // An arrow across the tab: a line with a head at its end.
                let from = mark.frame.minX + 2, to = mark.frame.maxX - 2
                guard to - from > 4 else { continue }

                let path = NSBezierPath()
                path.lineWidth = 1
                path.move(to: NSPoint(x: from, y: middle))
                path.line(to: NSPoint(x: to, y: middle))
                path.move(to: NSPoint(x: to - 3, y: middle - 3))
                path.line(to: NSPoint(x: to, y: middle))
                path.line(to: NSPoint(x: to - 3, y: middle + 3))
                path.stroke()
            }
        }
    }

    // MARK: Fold placeholders

    /// Where the text of a folded block was hidden: the offset at the end of its header line. A
    /// small "…" box is drawn after the header text there, and a click on it opens the fold.
    var foldPlaceholders: [Int] = [] {
        didSet { if foldPlaceholders != oldValue { needsDisplay = true } }
    }

    /// A folded block's box was clicked: the offset it stands at.
    var onPlaceholderClick: ((Int) -> Void)?

    static let placeholderText = "…"

    /// The boxes to draw, in this view's coordinates, with the offset each stands at.
    func placeholderRects() -> [(offset: Int, rect: NSRect)] {
        guard let manager = textLayoutManager, let content = manager.textContentManager,
              let font else { return [] }

        let size = (Self.placeholderText as NSString).size(withAttributes: [.font: font])
        var result: [(Int, NSRect)] = []
        for offset in foldPlaceholders {
            guard let location = content.location(content.documentRange.location, offsetBy: offset) else { continue }

            var edge: NSRect?
            manager.enumerateTextSegments(
                in: NSTextRange(location: location),
                type: .standard,
                options: [.rangeNotRequired]
            ) { _, frame, _, _ in
                edge = frame

                return false
            }
            guard let edge else { continue }

            let origin = textContainerOrigin
            let box = NSRect(
                x: edge.maxX + origin.x + 5,
                y: edge.minY + origin.y + 1,
                width: ceil(size.width) + 10,
                height: max(edge.height - 2, size.height)
            )
            result.append((offset, box))
        }

        return result
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawWhitespaceMarks(in: dirtyRect)
        guard !foldPlaceholders.isEmpty, let font else { return }

        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
        for (_, box) in placeholderRects() where box.intersects(dirtyRect) {
            NSColor.secondaryLabelColor.withAlphaComponent(0.18).setFill()
            NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3).fill()
            let text = NSAttributedString(string: Self.placeholderText, attributes: attributes)
            let size = text.size()
            text.draw(at: NSPoint(x: box.midX - size.width / 2, y: box.midY - size.height / 2))
        }
    }

    // MARK: Duplicate

    /// Duplicate Line. Without a selection the caret's line is copied below it and the caret moves
    /// to the copy, in the same column. A selection inside one line is repeated right after
    /// itself; a selection over several lines repeats those whole lines below them. Either way the
    /// copy is selected, and the whole thing is one edit, so one Undo takes it back.
    @objc func duplicateLine(_ sender: Any?) {
        guard !hasMarkedText(), let storage = textStorage else { return }

        let text = storage.mutableString
        let selection = selectedRange()
        let lines = text.lineRange(for: selection)
        let lastIsOpen = lines.upperBound == text.length && lines.length > 0
            && text.character(at: lines.upperBound - 1) != 0x0A
        let isWithinOneLine = selection.length > 0
            && text.lineRange(for: NSRange(location: selection.location, length: 0)) == lines
            && NSMaxRange(selection) <= lines.upperBound

        if selection.length > 0, isWithinOneLine, selection != lines {
            let copy = text.substring(with: selection)
            insertText(copy, replacementRange: NSRange(location: NSMaxRange(selection), length: 0))
            setSelectedRange(NSRange(location: NSMaxRange(selection), length: selection.length))

            return
        }

        var copy = text.substring(with: lines)
        if lastIsOpen { copy = "\n" + copy }

        insertText(copy, replacementRange: NSRange(location: lines.upperBound, length: 0))
        let shift = lastIsOpen ? lines.length + 1 : lines.length
        setSelectedRange(NSRange(location: selection.location + shift, length: selection.length))
    }

    // MARK: Comment

    /// Toggle Line Comment. If every line that has text starts with the language's comment marker
    /// the marker (and the space after it) is taken away; otherwise the marker and a space are put
    /// at the shallowest indentation among the lines, so the block stays lined up. Blank lines are
    /// left alone unless all of them are blank. One edit, one Undo; the selection follows the text.
    @objc func toggleLineComment(_ sender: Any?) {
        guard !hasMarkedText(), let storage = textStorage, let marker = hooks?.lineCommentPrefix?() else { return }

        let text = storage.mutableString
        let selection = selectedRange()
        // A selection that ends at the very start of a line does not include that line.
        var end = NSMaxRange(selection)
        if selection.length > 0, text.lineRange(for: NSRange(location: end, length: 0)).location == end { end -= 1 }

        let region = text.lineRange(for: NSRange(location: selection.location, length: end - selection.location))

        var lines: [NSRange] = []
        var position = region.location
        while position < region.upperBound {
            let line = text.lineRange(for: NSRange(location: position, length: 0))
            lines.append(line)
            position = line.upperBound
        }
        guard !lines.isEmpty else { return }

        func indentWidth(_ line: NSRange) -> Int {
            var index = line.location
            while index < line.upperBound, [0x20, 0x09].contains(text.character(at: index)) { index += 1 }

            return index - line.location
        }

        func isBlank(_ line: NSRange) -> Bool {
            var index = line.location + indentWidth(line)
            while index < line.upperBound, [0x0A, 0x0D].contains(text.character(at: index)) { index += 1 }

            return index == line.upperBound
        }

        func hasMarker(_ line: NSRange) -> Bool {
            let start = line.location + indentWidth(line)

            return text.substring(from: start).hasPrefix(marker)
        }

        let counted = lines.filter { !isBlank($0) }
        let targets = counted.isEmpty ? lines : counted
        let uncomment = !counted.isEmpty && counted.allSatisfy(hasMarker)
        let column = targets.map(indentWidth).min() ?? 0

        var result = ""
        var edits: [(line: NSRange, column: Int, delta: Int)] = []
        for line in lines {
            let content = text.substring(with: line)
            guard targets.contains(where: { $0 == line }) else {
                result += content
                edits.append((line, 0, 0))
                continue
            }

            let nsContent = content as NSString
            if uncomment {
                let at = indentWidth(line)
                let spaced = nsContent.substring(from: at + marker.utf16.count).hasPrefix(" ")
                let removed = marker.utf16.count + (spaced ? 1 : 0)
                result += nsContent.replacingCharacters(in: NSRange(location: at, length: removed), with: "")
                edits.append((line, at, -removed))
            } else {
                let inserted = marker + " "
                result += nsContent.replacingCharacters(in: NSRange(location: column, length: 0), with: inserted)
                edits.append((line, column, inserted.utf16.count))
            }
        }

        func mapped(_ offset: Int) -> Int {
            var shift = 0
            for edit in edits where edit.delta != 0 {
                if offset >= edit.line.upperBound {
                    shift += edit.delta
                } else if offset >= edit.line.location {
                    let inLine = offset - edit.line.location
                    shift += edit.delta > 0
                        ? (inLine >= edit.column ? edit.delta : 0)
                        : -min(-edit.delta, max(0, inLine - edit.column))
                }
            }

            return offset + shift
        }

        insertText(result, replacementRange: region)
        let start = mapped(selection.location)
        setSelectedRange(NSRange(location: start, length: max(0, mapped(NSMaxRange(selection)) - start)))
    }

    // MARK: Tab

    /// The width of one indent level, in columns; the tab key and the width of a tab character
    /// agree on it.
    static let indentWidth = 4

    /// The tab key types spaces up to the next indent column, so the caret lands where the code
    /// lines up whatever the line holds before it. (An existing tab character is measured to the
    /// same columns.)
    override func insertTab(_ sender: Any?) {
        guard !hasMarkedText(), let storage = textStorage else { return super.insertTab(sender) }

        let text = storage.mutableString
        let selection = selectedRange()
        let lineStart = text.lineRange(for: NSRange(location: selection.location, length: 0)).location
        var column = 0
        for index in lineStart..<selection.location {
            column = text.character(at: index) == 0x09
                ? (column / Self.indentWidth + 1) * Self.indentWidth
                : column + 1
        }

        insertText(
            String(repeating: " ", count: Self.indentWidth - column % Self.indentWidth),
            replacementRange: selection
        )
    }

    /// Return starts the new line at the indentation of the line it was pressed in (the part of it
    /// before the caret), so a second statement in a function lines up with the first. After an
    /// opening bracket the line goes one level deeper; between a bracket and its closer the closer
    /// moves to a line of its own at the outer level and the caret stays on the inner one.
    override func insertNewline(_ sender: Any?) {
        guard !hasMarkedText(), let storage = textStorage else { return super.insertNewline(sender) }

        let text = storage.mutableString
        let selection = selectedRange()
        let lineStart = text.lineRange(for: NSRange(location: selection.location, length: 0)).location
        var end = lineStart
        while end < selection.location, [0x20, 0x09].contains(text.character(at: end)) { end += 1 }

        let indent = text.substring(with: NSRange(location: lineStart, length: end - lineStart))
        let opener = Self.scan(text, from: lineStart, to: selection.location).lastCode.flatMap { Self.closers[$0] }
        guard let closer = opener else {
            insertText("\n" + indent, replacementRange: selection)

            return
        }

        let inner = indent + String(repeating: " ", count: Self.indentWidth)
        let selectionEnd = selection.location + selection.length
        if selectionEnd < text.length, text.character(at: selectionEnd) == closer {
            insertText("\n" + inner + "\n" + indent, replacementRange: selection)
            setSelectedRange(NSRange(location: selection.location + 1 + inner.utf16.count, length: 0))
        } else {
            insertText("\n" + inner, replacementRange: selection)
        }
    }

    /// The closing character of each opening bracket.
    private static let closers: [unichar: unichar] = [0x7B: 0x7D, 0x28: 0x29, 0x5B: 0x5D]

    /// What the part of a line before a position says about code: the last character that is code
    /// (not blank, not in a comment; a string counts as its closing quote), and whether the position
    /// is inside a string or a `//` comment.
    private static func scan(
        _ text: NSString,
        from start: Int,
        to end: Int
    ) -> (lastCode: unichar?, inString: Bool, inComment: Bool) {
        var last: unichar?
        var inString = false
        var index = start
        while index < end {
            let character = text.character(at: index)
            if inString {
                if character == 0x5C { index += 1 } else if character == 0x22 {
                    inString = false
                    last = character
                }
            } else if character == 0x22 {
                inString = true
            } else if character == 0x2F, index + 1 < end, text.character(at: index + 1) == 0x2F {
                return (last, false, true)
            } else if character != 0x20, character != 0x09 {
                last = character
            }

            index += 1
        }

        return (last, inString, false)
    }

    /// Typing an opening bracket or a quote adds its partner; typing the partner in front of itself
    /// steps over it. True if the typing was handled.
    private func handlePairing(_ string: Any) -> Bool {
        guard let typed = string as? String, typed.utf16.count == 1, let character = typed.utf16.first,
              !hasMarkedText(), let storage = textStorage, selectedRange().length == 0 else { return false }

        let text = storage.mutableString
        let caret = selectedRange().location
        let next: unichar? = caret < text.length ? text.character(at: caret) : nil
        let lineStart = text.lineRange(for: NSRange(location: caret, length: 0)).location
        let state = Self.scan(text, from: lineStart, to: caret)

        if (Self.closers.values.contains(character) || character == 0x22), next == character {
            setSelectedRange(NSRange(location: caret + 1, length: 0))

            return true
        }

        guard !state.inComment else { return false }

        let isOpener = Self.closers[character] != nil
        guard isOpener && !state.inString || character == 0x22 && !state.inString else { return false }

        // Pair only in front of a blank, the end of the line or a closer, and a quote only when it
        // does not follow a word (an apostrophe-like use) or another quote.
        if let next, ![0x20, 0x09, 0x0A, 0x29, 0x5D, 0x7D, 0x2C, 0x3B].contains(next) { return false }

        if character == 0x22, caret > lineStart {
            let previous = text.character(at: caret - 1)
            if previous == 0x22 || previous == 0x5C || CharacterSet.alphanumerics
                .contains(UnicodeScalar(previous) ?? " ") {
                return false
            }
        }

        let partner = character == 0x22 ? character : Self.closers[character] ?? character
        insertPair(opening: character, closing: partner, at: caret)

        return true
    }

    private func insertPair(opening: unichar, closing: unichar, at caret: Int) {
        let pair = String(utf16CodeUnits: [opening, closing], count: 2)
        insertText(pair, replacementRange: NSRange(location: caret, length: 0))
        setSelectedRange(NSRange(location: caret + 1, length: 0))
    }

    /// Backspace between an empty pair removes both halves.
    override func deleteBackward(_ sender: Any?) {
        let selection = selectedRange()
        if selection.length == 0, selection.location > 0, !hasMarkedText(), let storage = textStorage {
            let text = storage.mutableString
            if selection.location < text.length {
                let before = text.character(at: selection.location - 1)
                let after = text.character(at: selection.location)
                if Self.closers[before] == after || before == 0x22 && after == 0x22 {
                    insertText("", replacementRange: NSRange(location: selection.location - 1, length: 2))

                    return
                }
            }
        }

        super.deleteBackward(sender)
    }

    /// A closing bracket typed on a line that holds only indentation steps back one level.
    private func dedentRange(forClosing string: Any) -> NSRange? {
        guard let typed = string as? String, typed.utf16.count == 1,
              let character = typed.utf16.first, Self.closers.values.contains(character),
              !hasMarkedText(), let storage = textStorage else { return nil }

        let selection = selectedRange()
        guard selection.length == 0 else { return nil }

        let text = storage.mutableString
        let lineStart = text.lineRange(for: selection).location
        guard selection.location > lineStart else { return nil }

        for index in lineStart..<selection.location where ![0x20, 0x09].contains(text.character(at: index)) {
            return nil
        }

        let last = text.character(at: selection.location - 1)
        if last == 0x09 { return NSRange(location: selection.location - 1, length: 1) }

        var width = 0
        while width < Self.indentWidth, selection.location - width > lineStart,
              text.character(at: selection.location - width - 1) == 0x20 { width += 1 }

        return width == 0 ? nil : NSRange(location: selection.location - width, length: width)
    }

    // MARK: The pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self && area.userInfo?["code"] != nil {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: ["code": true]
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        hooks?.pointerMoved?(characterOffset(atViewPoint: convert(event.locationInWindow, from: nil)))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hooks?.pointerMoved?(nil)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let hit = placeholderRects().first(where: { $0.rect.contains(point) }) {
            onPlaceholderClick?(hit.offset)

            return
        }

        if handleCommandClick(event) { return }

        super.mouseDown(with: event)
    }

    /// A click takes a description away; a Command-click on a character is the editor's if the
    /// application uses it. True if the click is used up. (The rest is the text view's own, which
    /// follows the pointer until the button is released.)
    func handleCommandClick(_ event: NSEvent) -> Bool {
        hooks?.interactionBegan?()
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers == .command, !hasMarkedText(),
              let offset = characterOffset(atViewPoint: convert(event.locationInWindow, from: nil)) else {
            return false
        }

        return hooks?.commandClick?(offset) == true
    }

    override func scrollWheel(with event: NSEvent) {
        hooks?.interactionBegan?()
        super.scrollWheel(with: event)
    }

    /// The system command behind Escape and F5. The default one offers words from a dictionary;
    /// here it is the editor's completion.
    override func complete(_ sender: Any?) {
        if let request = hooks?.requestCompletion { request() } else { super.complete(sender) }
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        guard let bridge else {
            super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)

            return
        }

        let isEmpty = (string as? NSAttributedString)?.length == 0 || (string as? String)?.isEmpty == true
        let wasComposing = bridge.beginMarkedTextUpdate(isEmpty: isEmpty)
        bridge.forcedOrigin = .composition
        bridge.performCoalesced {
            super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        }
        bridge.forcedOrigin = nil
        bridge.finishMarkedTextUpdate(wasComposing: wasComposing)
    }

    override func unmarkText() {
        guard let bridge else { return super.unmarkText() }

        bridge.performCoalesced(unmarking: markedRange()) { super.unmarkText() }
        bridge.syncComposition()
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        if replacementRange.location == NSNotFound {
            if handlePairing(string) { return }

            if let range = dedentRange(forClosing: string) { return insertText(string, replacementRange: range) }
        }

        guard let bridge else { return super.insertText(string, replacementRange: replacementRange) }

        bridge.performCoalesced { super.insertText(string, replacementRange: replacementRange) }
        bridge.syncComposition()
    }
}
