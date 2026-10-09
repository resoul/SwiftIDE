import AppKit
import EditorPlatformTextKit
import EditorUI
import IDEApplication
import IDEDomain
import Testing

/// A real editor in a window that is laid out and drawn into a bitmap, never shown.
@MainActor
private struct Gutter {
    let editor: TextKitEditor
    let session: DocumentSession
    let lineIndex: DocumentLineIndex
    let host: EditorHostView
    let window: NSWindow

    init(_ text: String, width: CGFloat = 400, height: CGFloat = 300) {
        editor = TextKitEditorFactory.makeEditor(loadedText: text)
        session = DocumentSession(path: "Main.swift", backend: editor.backend)
        lineIndex = DocumentLineIndex(session: session, source: editor.backend)
        host = EditorHostView(editor: editor, lineIndex: lineIndex)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = host
        draw()
    }

    var ruler: LineNumberRulerView { host.verticalRulerView as! LineNumberRulerView }
    var labels: [LineNumberRulerView.Label] { ruler.visibleLabels() }

    /// Lays out and draws what is visible, as a screen refresh would.
    func draw() {
        host.layoutSubtreeIfNeeded()
        let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: bitmap)
    }

    /// Scrolls to a fraction of the document's height, as dragging the scroller would.
    func scroll(toFraction fraction: CGFloat) {
        let y = max(0, (editor.textView.frame.height - host.contentView.bounds.height) * fraction)
        host.contentView.scroll(to: NSPoint(x: 0, y: y))
        host.reflectScrolledClipView(host.contentView)
        draw()
    }
}

@Test @MainActor
func eachLineGetsItsNumberInOrder() {
    let g = Gutter("alpha\nbeta\r\ngamma\rdelta")
    #expect(g.labels.map(\.number) == [1, 2, 3, 4])
    let baselines = g.labels.map(\.baseline)
    #expect(baselines == baselines.sorted())
    let gaps = zip(baselines, baselines.dropFirst()).map { $1 - $0 }
    #expect(gaps.allSatisfy { abs($0 - gaps[0]) < 0.5 }, "rows of equal height")
}

@Test @MainActor
func aWrappedLineCarriesItsNumberOnTheFirstRowOnly() {
    let long = String(repeating: "word ", count: 80)   // wraps into several rows at this width
    let g = Gutter("\(long)\nshort\n", width: 300)
    #expect(g.labels.map(\.number) == [1, 2, 3])
    let baselines = g.labels.map(\.baseline)
    #expect(baselines[1] - baselines[0] > 3 * (baselines[2] - baselines[1]), "the second line starts below several rows")
}

@Test @MainActor
func theEmptyLastLineAfterATrailingNewlineIsNumbered() {
    let g = Gutter("one\ntwo\n")
    #expect(g.labels.map(\.number) == [1, 2, 3])
}

@Test @MainActor
func anEmptyDocumentHasLineOne() {
    let g = Gutter("")
    #expect(g.labels.map(\.number) == [1])
}

@Test @MainActor
func typingANewlineAddsANumber() {
    let g = Gutter("one\ntwo")
    #expect(g.labels.map(\.number) == [1, 2])
    g.editor.textView.insertText("\n", replacementRange: NSRange(location: 3, length: 0))
    g.draw()
    #expect(g.labels.map(\.number) == [1, 2, 3])
}

extension Gutter {
    /// The text of the row a label sits next to, found from the label's position alone.
    func rowText(of label: LineNumberRulerView.Label) -> String? {
        let point = ruler.convert(NSPoint(x: 0, y: label.baseline - 3), to: editor.textView)
        let origin = editor.textView.textContainerOrigin
        guard let layoutManager = editor.textView.textLayoutManager,
              let fragment = layoutManager.textLayoutFragment(for: NSPoint(x: point.x - origin.x, y: point.y - origin.y)),
              let paragraph = fragment.textElement as? NSTextParagraph else { return nil }
        return paragraph.attributedString.string.trimmingCharacters(in: .newlines)
    }
}

@Test @MainActor
func onlyTheLinesInViewAreLabelledWhateverTheFileSize() {
    let text = (1...20_000).map { "line \($0)" }.joined(separator: "\n")
    let g = Gutter(text, height: 300)
    #expect(g.labels.first?.number == 1)
    #expect(g.labels.count < 60)

    g.scroll(toFraction: 0.6)
    let labels = g.labels
    #expect(labels.count > 5 && labels.count < 60)
    // Each number sits next to the row that really holds that line: the text says its own number.
    for label in labels {
        #expect(g.rowText(of: label) == "line \(label.number)", "label \(label.number)")
    }
    let numbers = labels.map(\.number)
    #expect(numbers == Array(numbers[0]...numbers[0] + (numbers.count - 1)), "consecutive numbers")
    #expect(numbers[0] > 1000, "the view moved away from the top")
}

@Test @MainActor
func theMarginGrowsWithTheNumberOfDigits() {
    let g = Gutter("a\nb")
    let narrow = g.ruler.ruleThickness
    try? g.session.replaceText(String(repeating: "x\n", count: 120_000), expectedVersion: g.session.version)
    #expect(g.ruler.ruleThickness > narrow)
}

@Test @MainActor
func aLongFileCanBeScrolled() {
    // The view must grow to the document's height; a view stuck at its initial height has
    // nothing to scroll and shows the first screen forever.
    let g = Gutter((1...5_000).map { "line \($0)" }.joined(separator: "\n"), height: 300)
    #expect(g.editor.textView.frame.height > 10 * g.host.contentView.bounds.height)
}
