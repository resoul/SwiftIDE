import AppKit
import EditorPlatformTextKit
import IDEApplication
import IDEDomain
import IDETestSupport
import Testing

/// The obvious, slow definition of lines that the index must agree with.
private struct ReferenceLines {
    struct Line: Equatable { var start: Int; var content: Int; var terminator: LineTerminator }
    var lines: [Line] = []

    init(_ units: [UInt16]) {
        var start = 0, index = 0
        while index < units.count {
            let unit = units[index]
            if unit == 0x0A {
                lines.append(Line(start: start, content: index - start, terminator: .lf))
                index += 1; start = index
            } else if unit == 0x0D {
                if index + 1 < units.count, units[index + 1] == 0x0A {
                    lines.append(Line(start: start, content: index - start, terminator: .crlf))
                    index += 2
                } else {
                    lines.append(Line(start: start, content: index - start, terminator: .cr))
                    index += 1
                }
                start = index
            } else {
                index += 1
            }
        }
        lines.append(Line(start: start, content: index - start, terminator: .none))
    }
}

private func expectAgrees(
    _ index: LineIndex, with units: [UInt16], _ note: @autoclosure () -> String = "",
    everyLine: Bool = true, sourceLocation: SourceLocation = #_sourceLocation
) {
    let reference = ReferenceLines(units)
    #expect(index.utf16Length == units.count, "length \(note())", sourceLocation: sourceLocation)
    #expect(index.lineCount == reference.lines.count, "line count \(note())", sourceLocation: sourceLocation)
    guard index.lineCount == reference.lines.count else { return }
    // Checking every line is slow in a debug build; large documents do it on some steps only.
    let numbers = everyLine ? Array(reference.lines.indices) : (0..<80).map { _ in Int.random(in: 0..<reference.lines.count) }
    for number in numbers {
        let expected = reference.lines[number]
        let extent = index.lineExtent(number)
        guard index.startOffset(ofLine: number) == expected.start,
              extent.content == expected.content, extent.terminator == expected.terminator else {
            Issue.record("line \(number) differs \(note())", sourceLocation: sourceLocation)
            return
        }
    }
    // The longest line, by content: the first one if several are as long.
    let longest = reference.lines.enumerated().max { ($0.element.content, -$0.offset) < ($1.element.content, -$1.offset) }!
    #expect(index.longestLine.length == longest.element.content, "longest line length \(note())", sourceLocation: sourceLocation)
    #expect(index.longestLine.line == longest.offset, "longest line number \(note())", sourceLocation: sourceLocation)
    // Every offset belongs to the line that contains it; a line start is recognised as one.
    let probes = units.count < 200 ? Array(0...units.count) : (0..<60).map { _ in Int.random(in: 0...units.count) }
    for offset in probes {
        let expectedLine = reference.lines.lastIndex { $0.start <= offset }!
        guard index.line(containing: offset) == expectedLine else {
            Issue.record("line(containing: \(offset)) \(note())", sourceLocation: sourceLocation)
            return
        }
        let isStart = reference.lines[expectedLine].start == offset
        guard index.lineStarting(at: offset) == (isStart ? expectedLine : nil) else {
            Issue.record("lineStarting(at: \(offset)) \(note())", sourceLocation: sourceLocation)
            return
        }
    }
}


private func replaceOK(
    _ index: inout LineIndex, _ range: UTF16TextRange, with replacement: String,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    let applied = index.replace(range, with: replacement)
    #expect(applied, "the edit fits the document", sourceLocation: sourceLocation)
}

private func rejects(
    _ index: inout LineIndex, _ range: UTF16TextRange, with replacement: String,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    let applied = index.replace(range, with: replacement)
    #expect(!applied, "the edit does not fit the document", sourceLocation: sourceLocation)
}

private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

private let alphabet = ["a", "b", " ", "\n", "\r", "\r\n", "\n\r", "😀", "\n"]

private func randomText(_ generator: inout SeededGenerator, pieces: Int) -> String {
    (0..<pieces).map { _ in alphabet.randomElement(using: &generator)! }.joined()
}

@Test
func linesAreCountedForEveryTerminatorAndTheEmptyDocument() {
    for (text, expected) in [
        ("", [(0, LineTerminator.none)]),
        ("abc", [(3, .none)]),
        ("abc\n", [(3, .lf), (0, .none)]),
        ("a\r\nb\rc\n\n", [(1, .crlf), (1, .cr), (1, .lf), (0, .lf), (0, .none)]),
        ("\r\r\n\n\r", [(0, .cr), (0, .crlf), (0, .lf), (0, .cr), (0, .none)]),
    ] {
        let index = LineIndex(text)
        #expect(index.lineCount == expected.count, "\(text.debugDescription)")
        for (number, line) in expected.enumerated() {
            #expect(index.lineExtent(number).content == line.0)
            #expect(index.lineExtent(number).terminator == line.1)
        }
        expectAgrees(index, with: Array(text.utf16), text.debugDescription)
    }
}

@Test
func anInsertedLineFeedJoinsAnEarlierReturnIntoOneBreak() {
    var index = LineIndex("a\rb")
    // "\r" + "\n" becomes "\r\n": one line break, not two.
    replaceOK(&index, UTF16TextRange(location: 2, length: 0), with: "\n")
    expectAgrees(index, with: Array("a\r\nb".utf16))
    #expect(index.lineCount == 2)
}

@Test
func splittingOrJoiningACarriageReturnLineFeedPairIsFollowed() {
    var index = LineIndex("a\r\nb")
    replaceOK(&index, UTF16TextRange(location: 2, length: 0), with: "X")   // between \r and \n
    expectAgrees(index, with: Array("a\rX\nb".utf16))
    replaceOK(&index, UTF16TextRange(location: 2, length: 1), with: "")   // delete X: rejoin
    expectAgrees(index, with: Array("a\r\nb".utf16))
    replaceOK(&index, UTF16TextRange(location: 1, length: 1), with: "")   // delete \r
    expectAgrees(index, with: Array("a\nb".utf16))
}

@Test
func deletingTheTextBetweenAReturnAndALineFeedMakesThemOneBreak() {
    var index = LineIndex("a\rxyz\nb")
    replaceOK(&index, UTF16TextRange(location: 2, length: 3), with: "")
    expectAgrees(index, with: Array("a\r\nb".utf16))
}

@Test
func anEditThatDoesNotFitLeavesTheIndexUntouched() {
    var index = LineIndex("abc\ndef")
    rejects(&index, UTF16TextRange(location: 5, length: 9), with: "x")
    rejects(&index, UTF16TextRange(location: -1, length: 0), with: "x")
    expectAgrees(index, with: Array("abc\ndef".utf16))
}

@Test
func randomEditsKeepTheIndexEqualToAFullRescan() {
    var generator = SeededGenerator(seed: 0x11E5)
    for round in 0..<300 {
        var units = Array(randomText(&generator, pieces: Int.random(in: 0...40, using: &generator)).utf16)
        var index = LineIndex(String(decoding: units, as: UTF16.self))
        for step in 0..<40 {
            let location = Int.random(in: 0...units.count, using: &generator)
            let length = Int.random(in: 0...min(6, units.count - location), using: &generator)
            let replacement = randomText(&generator, pieces: Int.random(in: 0...4, using: &generator))
            replaceOK(&index, UTF16TextRange(location: location, length: length), with: replacement)
            units.replaceSubrange(location..<(location + length), with: Array(replacement.utf16))
            expectAgrees(index, with: units, "seed 0x11E5 round \(round) step \(step)")
        }
    }
}

@Test
func editsAcrossChunkBoundariesKeepTheIndexEqualToAFullRescan() {
    var generator = SeededGenerator(seed: 0xC4A9)
    // Several thousand lines span many chunks; edits of every size cross their boundaries.
    var units = Array(String(repeating: "line of text\r\n\n\rx\n", count: 300).utf16)
    var index = LineIndex(String(decoding: units, as: UTF16.self))
    expectAgrees(index, with: units, "initial")
    for step in 0..<60 {
        let location = Int.random(in: 0...units.count, using: &generator)
        let big = Bool.random(using: &generator)
        let length = Int.random(in: 0...min(big ? 1500 : 12, units.count - location), using: &generator)
        let replacement = big && Bool.random(using: &generator)
            ? String(repeating: "new\n", count: Int.random(in: 0...3000, using: &generator))
            : randomText(&generator, pieces: Int.random(in: 0...5, using: &generator))
        replaceOK(&index, UTF16TextRange(location: location, length: length), with: replacement)
        units.replaceSubrange(location..<(location + length), with: Array(replacement.utf16))
        expectAgrees(index, with: units, "seed 0xC4A9 step \(step)", everyLine: step % 10 == 0)
    }
}

@Test
func wipingAndRefillingTheDocumentWorks() {
    var index = LineIndex(String(repeating: "x\n", count: 3000))
    replaceOK(&index, UTF16TextRange(location: 0, length: 6000), with: "")
    expectAgrees(index, with: [])
    replaceOK(&index, UTF16TextRange(location: 0, length: 0), with: String(repeating: "y\r\n", count: 2500))
    expectAgrees(index, with: Array(String(repeating: "y\r\n", count: 2500).utf16))
}

// MARK: Following a session

@MainActor
private struct Tracked {
    let editor: TextKitEditor
    let session: DocumentSession
    let tracker: DocumentLineIndex

    init(_ text: String) {
        editor = TextKitEditorFactory.makeEditor(loadedText: text)
        session = DocumentSession(path: "Main.swift", backend: editor.backend)
        tracker = DocumentLineIndex(session: session, source: editor.backend)
    }

    func assertExact(_ note: String = "", sourceLocation: SourceLocation = #_sourceLocation) {
        expectAgrees(tracker.current, with: Array(editor.textView.string.utf16), note, sourceLocation: sourceLocation)
        #expect(tracker.rebuildCount == 0, "followed the edits without rereading the text \(note)", sourceLocation: sourceLocation)
    }

    func type(_ string: String, at location: Int, replacing length: Int = 0) {
        editor.textView.insertText(string, replacementRange: NSRange(location: location, length: length))
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.001))
    }
}

@Test @MainActor
func theIndexFollowsTypingProgrammaticEditsAndUndo() throws {
    let t = Tracked("one\ntwo\r\nthree")
    t.assertExact("initial")
    t.type("\n", at: 3)
    t.assertExact("typed newline")
    t.type("", at: 4, replacing: 4)
    t.assertExact("deleted a line")
    try t.session.apply(
        [DocumentEdit(range: UTF16TextRange(location: 0, length: 0), replacement: "head\r")],
        expectedVersion: t.session.version
    )
    t.assertExact("programmatic")
    t.type("\n", at: 5)   // completes the \r typed above into \r\n
    t.assertExact("typed newline after a return")
    for _ in 0..<4 {
        t.editor.undo.undoManager.undo()
        t.assertExact("undo")
    }
    while t.editor.undo.undoManager.canRedo {
        t.editor.undo.undoManager.redo()
        t.assertExact("redo")
    }
}

@Test @MainActor
func aWholeDocumentReplacementKeepsTheIndexExact() throws {
    let t = Tracked("a\nb\nc")
    try t.session.replaceText("x\r\ny\rz\n", expectedVersion: t.session.version)
    t.assertExact("replaced")
}

@Test @MainActor
func aChangeNobodyAnnouncedIsFollowedAsAWholeDocumentReplacement() throws {
    let t = Tracked("a\nb")
    let storage = try #require(t.editor.textView.textStorage)
    storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "ZZ\n")   // behind the session
    t.type("q", at: 0)
    t.assertExact("after the session noticed")
}

@Test @MainActor
func anIndexStartedWhileTheTextIsAheadOfTheSessionRebuildsWhenAsked() throws {
    let editor = TextKitEditorFactory.makeEditor(loadedText: "a\nb")
    let session = DocumentSession(path: "Main.swift", backend: editor.backend)
    let storage = try #require(editor.textView.textStorage)
    storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "ZZ\n")
    let tracker = DocumentLineIndex(session: session, source: editor.backend)
    expectAgrees(tracker.current, with: Array(editor.textView.string.utf16))
}

@Test
func theLongestLineIsKnownWithoutScanningTheText() {
    var index = LineIndex("a\nbbbbb\ncc\n")
    #expect(index.longestLine.length == 5 && index.longestLine.line == 1)
    replaceOK(&index, UTF16TextRange(location: 2, length: 5), with: "")          // the long line is emptied
    #expect(index.longestLine.length == 2 && index.longestLine.line == 2)
    replaceOK(&index, UTF16TextRange(location: 0, length: 0), with: String(repeating: "z", count: 40))
    #expect(index.longestLine.length == 41 && index.longestLine.line == 0)
    #expect(LineIndex("").longestLine.length == 0)
    // Terminators are not content: a line of 3 and a break is 3 long, also in CRLF.
    #expect(LineIndex("abc\r\nd").longestLine.length == 3)
}
