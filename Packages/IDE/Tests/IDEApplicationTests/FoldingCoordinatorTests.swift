import AppKit
import EditorPlatformTextKit
import EditorUI
import IDEApplication
import IDEDomain
import Testing

/// A real editor with folding, laid out in a window that is never shown.
@MainActor
private struct Folding {
    let editor: TextKitEditor
    let session: DocumentSession
    let host: EditorHostView
    let window: NSWindow
    let coordinator: FoldingCoordinator

    init(_ text: String) {
        editor = TextKitEditorFactory.makeEditor(loadedText: text)
        session = DocumentSession(path: "Main.swift", backend: editor.backend)
        let lineIndex = DocumentLineIndex(session: session, source: editor.backend)
        host = EditorHostView(editor: editor, lineIndex: lineIndex)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        coordinator = FoldingCoordinator(
            session: session,
            editor: editor,
            ruler: host.lineNumberRuler,
            lineIndex: lineIndex,
            isEnabled: { true },
            style: { .braces(characterLiterals: false) },
            delay: .milliseconds(5)
        )
        draw()
    }

    var ruler: LineNumberRulerView { host.lineNumberRuler! }
    var labels: [Int] { ruler.visibleLabels().map(\.number) }

    func draw() {
        host.layoutSubtreeIfNeeded()
        let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: bitmap)
    }

    func settle() async { try? await Task.sleep(for: .milliseconds(80)) }

    /// Waits for what the coordinator reads again after a change, up to a few seconds.
    func wait(until condition: () -> Bool) async {
        for _ in 0..<400 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    /// Types `text` at `offset` through the session, as a command would.
    func insert(_ text: String, at offset: Int) {
        try? session.apply(
            [DocumentEdit(range: UTF16TextRange(location: offset, length: 0), replacement: text)],
            expectedVersion: session.version
        )
    }
}

private let sample = "func f() {\n    a\n    b\n}\nlet x = 1\n"

@Test @MainActor
func theMarginMarksFoldableLinesAndFoldingHidesTheBodyFromTheLayoutAndTheNumbers() {
    let f = Folding(sample)
    #expect(f.ruler.foldMarks == [0: false] && f.ruler.showsFolding)
    #expect(f.labels == [1, 2, 3, 4, 5, 6])
    f.coordinator.toggle(line: 0)
    f.draw()
    #expect(f.ruler.foldMarks == [0: true] && f.labels == [1, 4, 5, 6], "the hidden lines have no numbers")
    #expect(f.editor.textView.string == sample, "the text is untouched")
    #expect(f.session.version == 0 && !f.session.isDirty)
    f.coordinator.toggle(line: 0)
    f.draw()
    #expect(f.labels == [1, 2, 3, 4, 5, 6] && f.editor.backend.hiddenRanges.isEmpty)
}

@Test @MainActor
func aClickOnTheArrowToggles() throws {
    let f = Folding(sample)
    let label = try #require(f.ruler.visibleLabels().first)
    let x = f.ruler.bounds.maxX - 6
    let y = label.baseline - 2
    #expect(f.ruler.foldLine(atX: x, y: y) == 0)
    #expect(f.ruler.foldLine(atX: 2, y: y) == nil, "only the arrow column counts")
    let second = try #require(f.ruler.visibleLabels().dropFirst().first)
    #expect(f.ruler.foldLine(atX: x, y: second.baseline - 2) == nil, "a line with nothing to fold")
    f.ruler.onToggleFold?(0)
    #expect(f.coordinator.model.isFolded(startLine: 0))
}

@Test @MainActor
func aCaretInsideTheFoldedTextGoesToTheEndOfTheHeaderAndGoingBackInOpensTheFold() {
    let f = Folding(sample)
    f.editor.textView.setSelectedRange(NSRange(location: 17, length: 0))   // inside "    a"
    f.coordinator.toggle(line: 0)
    #expect(f.editor.textView.selectedRange() == NSRange(location: 10, length: 0))
    #expect(f.coordinator.model.isFolded(startLine: 0))
    f.editor.textView.setSelectedRange(NSRange(location: 18, length: 0))
    #expect(!f.coordinator.model.isFolded(startLine: 0), "a jump into hidden text opens it")
}

@Test @MainActor
func editsKeepFoldsAboveAndTheHeaderAndOpenTheOneTheyTouch() async {
    let f = Folding("top\n" + sample)
    f.coordinator.toggle(line: 1)
    f.insert("x", at: 0)
    await f.wait { f.coordinator.model.regions.first?.headerStart == 5 }
    #expect(f.coordinator.model.isFolded(startLine: 1) && f.ruler.foldMarks == [1: true])
    f.insert("zz", at: 4 + 1 + 10)   // end of the header line
    await f.wait { f.coordinator.model.regions.first?.hidden.lowerBound == 18 }
    #expect(f.coordinator.model.isFolded(startLine: 1))
    f.insert("q", at: f.coordinator.model.folded[0].hidden.lowerBound + 2)
    await f.wait { f.coordinator.model.folded.isEmpty }
    #expect(!f.coordinator.model.isFolded(startLine: 1) && f.editor.backend.hiddenRanges.isEmpty)
}

@Test @MainActor
func foldAndUnfoldCommandsActAtTheCaretAndAllFoldsAtOnce() {
    let text = "class A {\n    func f() {\n        x\n        y\n    }\n    var v = 1\n}\n"
    let f = Folding(text)
    f.editor.textView.setSelectedRange(NSRange(location: 30, length: 0))   // inside f's body
    f.coordinator.foldAtCaret()
    #expect(f.coordinator.model.isFolded(startLine: 1) && !f.coordinator.model.isFolded(startLine: 0))
    f.coordinator.foldAtCaret()
    #expect(f.coordinator.model.isFolded(startLine: 0), "the next call folds the block around it")
    f.coordinator.unfoldAtCaret()
    #expect(!f.coordinator.model.isFolded(startLine: 0) && f.coordinator.model.isFolded(startLine: 1))
    f.coordinator.unfoldAll()
    #expect(f.coordinator.model.folded.isEmpty)
    f.coordinator.foldAll()
    #expect(f.coordinator.model.isFolded(startLine: 0) && f.coordinator.model.isFolded(startLine: 1))
}

@Test @MainActor
func stoppingShowsEverythingAgain() {
    let f = Folding(sample)
    f.coordinator.toggle(line: 0)
    #expect(!f.editor.backend.hiddenRanges.isEmpty)
    f.coordinator.stop()
    #expect(f.editor.backend.hiddenRanges.isEmpty)
    f.coordinator.stop()
}

@Test @MainActor
func aFoldedHeaderShowsABoxAfterItsTextAndAClickOnItOpensTheFold() throws {
    let f = Folding(sample)
    #expect(f.editor.textView.foldPlaceholderFrames.isEmpty)
    f.coordinator.toggle(line: 0)
    f.draw()
    let boxes = f.editor.textView.foldPlaceholderFrames
    #expect(boxes.map(\.offset) == [10])
    let headerEnd = try #require(f.editor.textView.firstRectForOffset(10))
    #expect(boxes[0].frame.minX > headerEnd.maxX && boxes[0].frame.width > 8)
    #expect(f.editor.textView.clickFoldPlaceholder(at: 10))
    #expect(!f.coordinator.model.isFolded(startLine: 0) && f.editor.textView.foldPlaceholderFrames.isEmpty)
    #expect(!f.editor.textView.clickFoldPlaceholder(at: 10))
}

@Test @MainActor
func theBoxStandsBeforeACRLFTerminatorAndGoesWhenFoldingStops() {
    let f = Folding("func f() {\r\n    a\r\n    b\r\n}\r\n")
    f.coordinator.toggle(line: 0)
    #expect(f.editor.textView.foldPlaceholderFrames.map(\.offset) == [10])
    f.coordinator.stop()
    #expect(f.editor.textView.foldPlaceholderFrames.isEmpty)
}

@MainActor
private extension NSTextView {
    /// The rectangle of the character at `offset`, in this view's coordinates.
    func firstRectForOffset(_ offset: Int) -> NSRect? {
        guard let window else { return nil }

        let screen = firstRect(forCharacterRange: NSRange(location: offset - 1, length: 1), actualRange: nil)

        return convert(window.convertFromScreen(screen), from: nil)
    }
}
