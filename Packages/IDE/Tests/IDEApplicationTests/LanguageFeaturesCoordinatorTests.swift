import AppKit
@testable import EditorPlatformTextKit
@testable import EditorUI
import IDEApplication
import IDEDomain
import IDETestSupport
import Testing

@MainActor
private final class Provider: HoverProviding, DefinitionProviding, DiagnosticsProviding {
    var hoverAnswer: HoverOutcome = .content(HoverContent(text: "a symbol"))
    var definitionAnswer: DefinitionOutcome = .nothing
    private(set) var hoverAsked: [Int] = []
    private(set) var definitionAsked: [Int] = []
    var report: DocumentDiagnostics?
    private var observers: [UUID: @MainActor () -> Void] = [:]

    func hover(for session: DocumentSession, offset: @MainActor () -> Int) async -> HoverOutcome {
        hoverAsked.append(offset())

        return hoverAnswer
    }

    func definition(for session: DocumentSession, offset: @MainActor () -> Int) async -> DefinitionOutcome {
        definitionAsked.append(offset())

        return definitionAnswer
    }

    func diagnostics(for session: DocumentSession) -> DocumentDiagnostics? { report }

    func subscribeToDiagnostics(for session: DocumentSession, _ observer: @escaping @MainActor () -> Void) -> UUID {
        let id = UUID()
        observers[id] = observer

        return id
    }

    func unsubscribeFromDiagnostics(_ id: UUID) { observers.removeValue(forKey: id) }

    func publish(_ report: DocumentDiagnostics?) {
        self.report = report
        for observer in Array(observers.values) { observer() }
    }
}

/// A real text view in a real window with a line-number margin, a session over its storage, and the coordinator.
@MainActor
private struct Fixture {
    static let text = "let value = compute(1)\nlet other = value + 2\n"
    let editor: TextKitEditor
    let session: DocumentSession
    let window: NSWindow
    let host: EditorHostView
    let provider = Provider()
    let clock = ManualDelayClock()
    let coordinator: LanguageFeaturesCoordinator
    let opened = Opened()
    var textView: NSTextView { editor.textView }

    @MainActor final class Opened { var places: [DefinitionLocation] = [] }

    init(_ text: String = Fixture.text) {
        editor = TextKitEditorFactory.makeEditor(loadedText: text)
        session = DocumentSession(path: "/w/Main.swift", backend: editor.backend)
        let lineIndex = DocumentLineIndex(session: session, source: editor.backend)
        host = EditorHostView(editor: editor, lineIndex: lineIndex)
        window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 700, height: 400), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        window.makeFirstResponder(editor.textView)
        coordinator = LanguageFeaturesCoordinator(session: session, editor: editor, host: host, lineIndex: lineIndex, provider: provider, clock: clock)
        let opened = opened
        coordinator.openLocation = { opened.places.append($0) }
        window.layoutIfNeeded()
        editor.textView.textLayoutManager?.ensureLayout(for: editor.textView.textLayoutManager!.documentRange)
    }

    func settle() async {
        for _ in 0..<40 { await Task.yield() }
    }

    /// The centre of a character, in the text view's coordinates.
    func point(ofCharacter index: Int) -> NSPoint {
        let screen = textView.firstRect(forCharacterRange: NSRange(location: index, length: 1), actualRange: nil)
        let box = textView.convert(window.convertFromScreen(screen), from: nil)

        return NSPoint(x: box.midX, y: box.midY)
    }

    func codeView() -> CodeTextView { textView as! CodeTextView }

    func event(_ type: NSEvent.EventType, at viewPoint: NSPoint, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: textView.convert(viewPoint, to: nil),
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!
    }
}

// MARK: Which character is under the pointer

@Test @MainActor
func theCharacterUnderAPointIsFoundAndNothingIsPastTheEndOfALine() {
    let f = Fixture()
    for index in [0, 4, 12, 20, 25] {
        #expect(f.textView.characterOffset(atViewPoint: f.point(ofCharacter: index)) == index, "character \(index)")
    }
    let endOfFirstLine = f.point(ofCharacter: 21)           // the last ")" of the first line
    #expect(f.textView.characterOffset(atViewPoint: NSPoint(x: endOfFirstLine.x + 200, y: endOfFirstLine.y)) == nil)
    #expect(f.textView.characterOffset(atViewPoint: NSPoint(x: -5, y: 5)) == nil, "outside the view")
}

// MARK: The pointer

@Test @MainActor
func aPointerThatRestsOnAWordAsksForItsDescriptionAndShowsItInASmallWindow() async {
    let f = Fixture()
    f.textView.mouseMoved(with: f.event(.mouseMoved, at: f.point(ofCharacter: 14)))   // in "compute"
    await f.settle()
    f.clock.advance(by: .milliseconds(500))
    await f.settle()
    #expect(f.provider.hoverAsked == [12])
    #expect(f.coordinator.popup.isVisible && f.coordinator.popup.text == "a symbol")

    let exit = NSEvent.enterExitEvent(with: .mouseExited, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: f.window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
    f.textView.mouseExited(with: exit)
    #expect(!f.coordinator.popup.isVisible)
}

@Test @MainActor
func typingOrClickingTakesTheDescriptionAway() async {
    let f = Fixture()
    f.textView.mouseMoved(with: f.event(.mouseMoved, at: f.point(ofCharacter: 14)))
    await f.settle()
    f.clock.advance(by: .milliseconds(500))
    await f.settle()
    #expect(f.coordinator.popup.isVisible)
    #expect(!f.codeView().handleCommandClick(f.event(.leftMouseDown, at: f.point(ofCharacter: 5))), "a plain click is the text view's own")
    #expect(!f.coordinator.popup.isVisible)

    f.textView.mouseMoved(with: f.event(.mouseMoved, at: f.point(ofCharacter: 14)))
    await f.settle()
    f.clock.advance(by: .milliseconds(500))
    await f.settle()
    #expect(f.coordinator.popup.isVisible)
    let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: f.window.windowNumber, context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)!
    f.textView.keyDown(with: key)
    #expect(!f.coordinator.popup.isVisible)
}

@Test @MainActor
func controlShiftSpaceAsksForTheDescriptionAtTheCaret() async {
    let f = Fixture()
    f.textView.setSelectedRange(NSRange(location: 13, length: 0))
    let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.control, .shift], timestamp: 0, windowNumber: f.window.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49)!
    f.textView.keyDown(with: key)
    await f.settle()
    #expect(f.provider.hoverAsked == [12] && f.coordinator.popup.isVisible, "no waiting for a key")
}

// MARK: Definition

@Test @MainActor
func aCommandClickJumpsToTheDefinitionInTheSameDocumentByMovingTheCaret() async {
    let f = Fixture()
    f.provider.definitionAnswer = .locations([DefinitionLocation(path: "/w/Main.swift", line: 0, character: 4, offset: 4)])
    #expect(f.codeView().handleCommandClick(f.event(.leftMouseDown, at: f.point(ofCharacter: 30), modifiers: .command)))   // "value" on line 2
    await f.settle()
    #expect(f.provider.definitionAsked.count == 1)
    #expect(f.textView.selectedRange() == NSRange(location: 4, length: 0), "the click itself did not move the caret")
}

@Test @MainActor
func aDefinitionInAnotherFileIsHandedToTheWindowToOpen() async {
    let f = Fixture()
    f.provider.definitionAnswer = .locations([DefinitionLocation(path: "/w/Other.swift", line: 9, character: 2)])
    f.textView.setSelectedRange(NSRange(location: 14, length: 0))
    f.coordinator.jumpToDefinition()
    await f.settle()
    #expect(f.opened.places == [DefinitionLocation(path: "/w/Other.swift", line: 9, character: 2)])
}

@Test @MainActor
func withNoDefinitionTheUserIsToldAndTheWordGoesAway() async {
    let f = Fixture()
    f.textView.setSelectedRange(NSRange(location: 14, length: 0))
    f.coordinator.jumpToDefinition()
    await f.settle()
    #expect(f.coordinator.popup.isVisible && f.coordinator.popup.text == "No definition found")
}

@Test @MainActor
func aClickWithOtherModifiersOrOnNothingIsTheTextViewsOwn() async {
    let f = Fixture()
    #expect(!f.codeView().handleCommandClick(f.event(.leftMouseDown, at: f.point(ofCharacter: 14), modifiers: [.command, .shift])))
    #expect(!f.codeView().handleCommandClick(f.event(.leftMouseDown, at: f.point(ofCharacter: 14), modifiers: [.option])))
    let endOfLine = f.point(ofCharacter: 21)
    #expect(!f.codeView().handleCommandClick(f.event(.leftMouseDown, at: NSPoint(x: endOfLine.x + 200, y: endOfLine.y), modifiers: .command)), "Command-click on no character")
    await f.settle()
    #expect(f.provider.definitionAsked.isEmpty, "Command-Shift-click extends a selection")
}

// MARK: Problems

@Test @MainActor
func aReportMarksTheLinesInTheMarginAndCountsThem() async throws {
    let f = Fixture()
    f.provider.publish(DocumentDiagnostics(items: [
        DocumentDiagnostic(range: UTF16TextRange(location: 12, length: 7), severity: .error, message: "cannot find 'compute'"),
        DocumentDiagnostic(range: UTF16TextRange(location: 27, length: 5), severity: .warning, message: "unused"),
    ], version: f.session.version, isVerified: false))

    let ruler = try #require(f.host.lineNumberRuler)
    #expect(ruler.problemLines == [0: .error, 1: .warning])
    #expect(f.coordinator.diagnostics.summary.text == "1 error, 1 warning")

    f.provider.publish(nil)
    #expect(ruler.problemLines.isEmpty && f.coordinator.diagnostics.summary.text == nil, "all taken off")
}

@Test @MainActor
func theProblemAtAPlaceIsInTheDescriptionBeforeWhatTheServerSays() async {
    let f = Fixture()
    f.provider.publish(DocumentDiagnostics(items: [
        DocumentDiagnostic(range: UTF16TextRange(location: 12, length: 7), severity: .error, message: "cannot find 'compute'"),
    ], version: f.session.version, isVerified: false))
    f.textView.mouseMoved(with: f.event(.mouseMoved, at: f.point(ofCharacter: 14)))
    await f.settle()
    f.clock.advance(by: .milliseconds(500))
    await f.settle()
    #expect(f.coordinator.popup.text == "error: cannot find 'compute'\n\na symbol")
}

@Test @MainActor
func aProblemMovesWithTheTextWhileItIsTyped() async throws {
    let f = Fixture()
    f.provider.publish(DocumentDiagnostics(items: [
        DocumentDiagnostic(range: UTF16TextRange(location: 4, length: 5), severity: .error, message: "bad"),
    ], version: f.session.version, isVerified: false))
    f.textView.insertText("// hi\n", replacementRange: NSRange(location: 0, length: 0))
    #expect(f.coordinator.diagnostics.marks.first?.range == UTF16TextRange(location: 10, length: 5))
    #expect(f.coordinator.diagnostics.marks.first?.isStale == true)
    #expect(f.host.lineNumberRuler?.problemLines == [1: .error], "the margin follows the line it moved to")
}

// MARK: The small window

@Test @MainActor
func aLongDescriptionIsCutAndMarked() {
    let many = (1...40).map { "line \($0)" }.joined(separator: "\n")
    let cut = HoverPopup.trimmed(many)
    #expect(cut.components(separatedBy: "\n").count == HoverPopup.maximumLines && cut.hasSuffix("…"))
    #expect(HoverPopup.trimmed("short") == "short")
    #expect(HoverPopup.trimmed(String(repeating: "x", count: 5_000)).count == HoverPopup.maximumCharacters + 1)
}

@Test @MainActor
func theWordRangeStopsAtNonWordCharactersAndAtTheEnds() {
    let text = "let foo_bar2 = (x)"
    func word(_ offset: Int) -> UTF16TextRange? {
        WordRange.around(offset, length: text.utf16.count) { range in
            (text as NSString).substring(with: NSRange(location: range.location, length: range.length))
        }
    }
    #expect(word(4) == UTF16TextRange(location: 4, length: 8) && word(11) == UTF16TextRange(location: 4, length: 8))
    #expect(word(0) == UTF16TextRange(location: 0, length: 3))
    #expect(word(3) == nil && word(14) == nil && word(17) == nil)
    #expect(word(16) == UTF16TextRange(location: 16, length: 1))
    #expect(word(-1) == nil && word(18) == nil)
}

// MARK: What is drawn

/// How many pixels of the view, over a rectangle (view coordinates), are strongly red.
@MainActor
private func redPixels(in view: NSView, rect: NSRect) -> Int {
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return -1 }

    view.cacheDisplay(in: view.bounds, to: bitmap)
    var count = 0
    let scale = CGFloat(bitmap.pixelsWide) / view.bounds.width
    for y in Int(rect.minY * scale)..<Int(rect.maxY * scale) {
        for x in Int(rect.minX * scale)..<Int(rect.maxX * scale) {
            guard let colour = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }

            if colour.redComponent > 0.7, colour.greenComponent < 0.4, colour.blueComponent < 0.4 { count += 1 }
        }
    }

    return count
}

@Test @MainActor
func anErrorIsReallyDrawnAsRedUnderTheWordAndGoneWhenItIsCleared() async throws {
    let f = Fixture()
    f.window.layoutIfNeeded()
    let word = f.textView.convert(f.window.convertFromScreen(f.textView.firstRect(forCharacterRange: NSRange(location: 12, length: 7), actualRange: nil)), from: nil)
    let area = f.host.convert(word, from: f.textView).insetBy(dx: -2, dy: -4)
    #expect(redPixels(in: f.host, rect: area) == 0, "nothing red before")

    f.provider.publish(DocumentDiagnostics(items: [
        DocumentDiagnostic(range: UTF16TextRange(location: 12, length: 7), severity: .error, message: "bad"),
    ], version: f.session.version, isVerified: false))
    f.window.layoutIfNeeded()
    f.textView.displayIfNeeded()
    let drawn = redPixels(in: f.host, rect: area)
    #expect(drawn > 10, "\(drawn) red pixels under the word")

    f.provider.publish(nil)
    f.textView.displayIfNeeded()
    #expect(redPixels(in: f.host, rect: area) == 0, "and none after")
}

@Test @MainActor
func aProblemIsReallyDrawnUnderTheWordAndTheOverlayTakesNoClicks() async throws {
    let f = Fixture()
    f.window.layoutIfNeeded()
    let word = f.textView.convert(f.window.convertFromScreen(f.textView.firstRect(forCharacterRange: NSRange(location: 12, length: 7), actualRange: nil)), from: nil)
    let area = f.host.convert(word, from: f.textView).insetBy(dx: -2, dy: -4)
    #expect(redPixels(in: f.host, rect: area) == 0, "nothing red before")

    f.provider.publish(DocumentDiagnostics(items: [
        DocumentDiagnostic(range: UTF16TextRange(location: 12, length: 7), severity: .error, message: "bad"),
    ], version: f.session.version, isVerified: false))
    let drawn = redPixels(in: f.host, rect: area)
    #expect(drawn > 10, "\(drawn) red pixels under the word")
    let beside = f.host.convert(NSRect(x: word.minX, y: word.minY + 3, width: word.width, height: 4), from: f.textView)
    #expect(redPixels(in: f.host, rect: beside) == 0, "and none through the middle of the letters")

    let hit = f.textView.hitTest(f.textView.convert(NSPoint(x: word.midX, y: word.midY), to: f.textView.superview))
    #expect(hit === f.textView, "clicks go to the text")

    f.provider.publish(nil)
    #expect(redPixels(in: f.host, rect: area) == 0, "none after")
}

@Test @MainActor
func theLessASureAPlaceIsThePalerItsLine() {
    func alpha(_ freshness: DiagnosticMark.Freshness) -> CGFloat {
        DiagnosticsPresenter.colour(for: DiagnosticMark(range: UTF16TextRange(location: 0, length: 1), severity: .error, message: "", freshness: freshness)).alphaComponent
    }
    #expect(alpha(.verified) == 1)
    #expect(alpha(.unverified) < alpha(.verified) && alpha(.stale) < alpha(.unverified))
}

@Test @MainActor
func anEmptyRangeIsDrawnUnderACharacterAndNothingBeyondTheText() {
    #expect(DiagnosticsPresenter.visibleRange(of: UTF16TextRange(location: 5, length: 0), documentLength: 10) == UTF16TextRange(location: 5, length: 1))
    #expect(DiagnosticsPresenter.visibleRange(of: UTF16TextRange(location: 10, length: 0), documentLength: 10) == UTF16TextRange(location: 9, length: 1), "at the end: the one before")
    #expect(DiagnosticsPresenter.visibleRange(of: UTF16TextRange(location: 8, length: 5), documentLength: 10) == UTF16TextRange(location: 8, length: 2), "cut at the end")
    #expect(DiagnosticsPresenter.visibleRange(of: UTF16TextRange(location: 11, length: 1), documentLength: 10) == nil)
    #expect(DiagnosticsPresenter.visibleRange(of: UTF16TextRange(location: 0, length: 0), documentLength: 0) == nil)
}

@Test @MainActor
func theMarginDrawsADotBesideTheNumberOfALineWithAProblem() async throws {
    let f = Fixture()
    f.window.layoutIfNeeded()
    let ruler = try #require(f.host.lineNumberRuler)
    let margin = NSRect(x: 0, y: 0, width: 12, height: 40)
    let before = redPixels(in: ruler, rect: margin.intersection(ruler.bounds))
    #expect(before == 0)

    f.provider.publish(DocumentDiagnostics(items: [
        DocumentDiagnostic(range: UTF16TextRange(location: 12, length: 7), severity: .error, message: "bad"),
    ], version: f.session.version, isVerified: false))
    ruler.displayIfNeeded()
    let after = redPixels(in: ruler, rect: NSRect(x: 0, y: 0, width: 12, height: ruler.bounds.height).intersection(ruler.bounds))
    #expect(after > 8, "a red dot of about six points: \(after) pixels")
}

@Test @MainActor
func anArrowKeyTakesTheDescriptionAwayEvenThoughItChangesNoText() async {
    let f = Fixture()
    f.textView.mouseMoved(with: f.event(.mouseMoved, at: f.point(ofCharacter: 14)))
    await f.settle()
    f.clock.advance(by: .milliseconds(500))
    await f.settle()
    #expect(f.coordinator.popup.isVisible)
    let arrow = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.numericPad, .function], timestamp: 0, windowNumber: f.window.windowNumber, context: nil, characters: "\u{F702}", charactersIgnoringModifiers: "\u{F702}", isARepeat: false, keyCode: 123)!
    f.textView.keyDown(with: arrow)
    #expect(!f.coordinator.popup.isVisible)
}

@Test @MainActor
func theRightHalfOfACharacterIsStillThatCharacter() {
    let f = Fixture()
    let screen = f.textView.firstRect(forCharacterRange: NSRange(location: 14, length: 1), actualRange: nil)
    let box = f.textView.convert(f.window.convertFromScreen(screen), from: nil)
    #expect(f.textView.characterOffset(atViewPoint: NSPoint(x: box.maxX - 1, y: box.midY)) == 14)
    #expect(f.textView.characterOffset(atViewPoint: NSPoint(x: box.minX + 1, y: box.midY)) == 14)
}

@Test @MainActor
func aJumpWithinALongDocumentScrollsToTheDefinition() async {
    let text = (1...300).map { "let value\($0) = \($0)" }.joined(separator: "\n") + "\n"
    let f = Fixture(text)
    let target = (text as NSString).range(of: "value290").location
    f.provider.definitionAnswer = .locations([DefinitionLocation(path: "/w/Main.swift", line: 289, character: 4, offset: target)])
    f.textView.setSelectedRange(NSRange(location: 4, length: 0))
    f.coordinator.jumpToDefinition()
    await f.settle()
    #expect(f.textView.selectedRange() == NSRange(location: target, length: 0))
    let caret = f.textView.firstRect(forCharacterRange: NSRange(location: target, length: 0), actualRange: nil)
    let box = f.textView.convert(f.window.convertFromScreen(caret), from: nil)
    #expect(f.textView.visibleRect.intersects(box), "the definition is in view")
}

// MARK: Choosing and coming back

@Test @MainActor
func severalDefinitionsGoToTheChooserAndTheChosenOneIsOpened() async {
    let f = Fixture()
    f.provider.definitionAnswer = .locations([
        DefinitionLocation(path: "/w/B.swift", line: 1, character: 0),
        DefinitionLocation(path: "/w/C.swift", line: 2, character: 4),
    ])
    var offered: [DefinitionLocation] = []
    f.coordinator.chooser = { places, _, pick in
        offered = places
        pick(places[1])
    }
    f.textView.setSelectedRange(NSRange(location: 14, length: 0))
    f.coordinator.jumpToDefinition()
    await f.settle()
    #expect(offered.count == 2 && f.opened.places == [DefinitionLocation(path: "/w/C.swift", line: 2, character: 4)])
}

@Test @MainActor
func theMenuNamesEachPlaceByFileAndLine() {
    let entries = LanguageFeaturesCoordinator.menuEntries(for: [
        DefinitionLocation(path: "/w/Sources/Lib/Greeter.swift", line: 9, character: 2),
        DefinitionLocation(path: "/w/Sources/App/main.swift", line: 0, character: 0),
    ])
    #expect(entries.map(\.title) == ["Greeter.swift:10  —  /w/Sources/Lib", "main.swift:1  —  /w/Sources/App"])
}

@Test @MainActor
func aJumpTellsTheWindowWhereItLeftSoThatItCanComeBack() async {
    let f = Fixture()
    var left: [Int] = []
    f.coordinator.willJump = { left.append($0) }
    f.textView.setSelectedRange(NSRange(location: 14, length: 0))
    f.provider.definitionAnswer = .locations([DefinitionLocation(path: "/w/Other.swift", line: 9, character: 2)])
    f.coordinator.jumpToDefinition()
    await f.settle()
    f.provider.definitionAnswer = .locations([DefinitionLocation(path: "/w/Main.swift", line: 0, character: 4, offset: 4)])
    f.coordinator.jumpToDefinition()
    await f.settle()
    #expect(left == [14, 14], "once for the other file, once for the move within this one")
    f.provider.definitionAnswer = .nothing
    f.coordinator.jumpToDefinition()
    await f.settle()
    #expect(left.count == 2, "nowhere to go: nothing left")
}

@Test
func theHistoryRemembersPlacesNewestLastAndForgetsWhatIsReturnedTo() {
    var history = NavigationHistory()
    #expect(!history.canGoBack && history.pop() == nil)
    let a = NavigationPlace(path: "/w/A.swift", line: 1, character: 2), b = NavigationPlace(path: "/w/B.swift", line: 3, character: 0)
    history.push(a)
    history.push(a)
    history.push(b)
    #expect(history.places == [a, b], "the same place twice in a row counts once")
    #expect(history.pop() == b && history.pop() == a && history.pop() == nil)
}

@Test
func theHistoryKeepsOnlyTheLatestHundred() {
    var history = NavigationHistory()
    for line in 0..<250 { history.push(NavigationPlace(path: "/w/A.swift", line: line, character: 0)) }
    #expect(history.places.count == NavigationHistory.limit)
    #expect(history.pop()?.line == 249 && history.places.first?.line == 150)
}

// MARK: A problem with no extent, and the message on the margin

@Test @MainActor
func aProblemBetweenCharactersIsReallyDrawnOverTheWholeLine() async throws {
    let f = Fixture("foo(\"x\")\n")
    f.window.layoutIfNeeded()
    let start = f.textView.convert(f.window.convertFromScreen(f.textView.firstRect(forCharacterRange: NSRange(location: 0, length: 3), actualRange: nil)), from: nil)
    let area = f.host.convert(start, from: f.textView).insetBy(dx: -2, dy: -4)
    #expect(redPixels(in: f.host, rect: area) == 0)

    f.provider.publish(DocumentDiagnostics(items: [
        DocumentDiagnostic(range: UTF16TextRange(location: 7, length: 0), severity: .error, message: "missing argument"),
    ], version: f.session.version, isVerified: false))
    f.window.layoutIfNeeded()
    f.textView.displayIfNeeded()
    let drawn = redPixels(in: f.host, rect: area)
    #expect(drawn > 10, "\(drawn) red pixels under the start of the line, far from the place reported")
}

@MainActor
private func marginRow(_ f: Fixture, line number: Int) throws -> (ruler: LineNumberRulerView, y: CGFloat) {
    f.window.layoutIfNeeded()
    let ruler = try #require(f.host.lineNumberRuler)
    let label = try #require(ruler.visibleLabels().first { $0.number == number })

    return (ruler, label.baseline - 3)
}

@Test @MainActor
func thePointerOnAMarginDotShowsWhatTheLineSaysAndLeavingTakesItAway() async throws {
    let f = Fixture()
    f.provider.publish(DocumentDiagnostics(items: [
        DocumentDiagnostic(range: UTF16TextRange(location: 12, length: 7), severity: .warning, message: "unused"),
        DocumentDiagnostic(range: UTF16TextRange(location: 20, length: 0), severity: .error, message: "cannot find 'compute'"),
    ], version: f.session.version, isVerified: false))

    let first = try marginRow(f, line: 1)
    first.ruler.pointerMoved(toY: first.y)
    #expect(f.coordinator.popup.isVisible)
    #expect(f.coordinator.popup.text == "error: cannot find 'compute'\nwarning: unused", "the worse first")

    first.ruler.pointerMoved(toY: nil)
    #expect(!f.coordinator.popup.isVisible)
}

@Test @MainActor
func aMarginRowWithoutAProblemShowsNothingAndMovingOffAProblemRowTakesItAway() async throws {
    let f = Fixture()
    f.provider.publish(DocumentDiagnostics(items: [
        DocumentDiagnostic(range: UTF16TextRange(location: 12, length: 7), severity: .error, message: "bad"),
    ], version: f.session.version, isVerified: false))

    let second = try marginRow(f, line: 2)
    second.ruler.pointerMoved(toY: second.y)
    #expect(!f.coordinator.popup.isVisible, "line 2 has no problem")

    let first = try marginRow(f, line: 1)
    first.ruler.pointerMoved(toY: first.y)
    #expect(f.coordinator.popup.isVisible)
    second.ruler.pointerMoved(toY: second.y)
    #expect(!f.coordinator.popup.isVisible, "moved to a line without one")
}

@Test @MainActor
func typingTakesTheMarginMessageAway() async throws {
    let f = Fixture()
    f.provider.publish(DocumentDiagnostics(items: [
        DocumentDiagnostic(range: UTF16TextRange(location: 12, length: 7), severity: .error, message: "bad"),
    ], version: f.session.version, isVerified: false))
    let first = try marginRow(f, line: 1)
    first.ruler.pointerMoved(toY: first.y)
    #expect(f.coordinator.popup.isVisible)

    f.textView.insertText("x", replacementRange: NSRange(location: 0, length: 0))
    #expect(!f.coordinator.popup.isVisible)
}

@Test @MainActor
func theMarginMessageIsAlsoTakenAwayWhenTheTextScrollsOrTheWindowChanges() async throws {
    let f = Fixture()
    f.provider.publish(DocumentDiagnostics(items: [
        DocumentDiagnostic(range: UTF16TextRange(location: 12, length: 7), severity: .error, message: "bad"),
    ], version: f.session.version, isVerified: false))
    let first = try marginRow(f, line: 1)
    first.ruler.pointerMoved(toY: first.y)
    f.coordinator.popup.onClose?()
    #expect(!f.coordinator.popup.isVisible)
}

@Test @MainActor
func theMarginIsToldOnlyWhenThePointerChangesLineNotOnEveryMove() throws {
    let f = Fixture()
    f.provider.publish(DocumentDiagnostics(items: [
        DocumentDiagnostic(range: UTF16TextRange(location: 12, length: 7), severity: .error, message: "bad"),
    ], version: f.session.version, isVerified: false))
    let first = try marginRow(f, line: 1)
    var told: [Int?] = []
    first.ruler.onProblemHover = { told.append($0) }

    for _ in 0..<5 { first.ruler.pointerMoved(toY: first.y) }
    first.ruler.pointerMoved(toY: nil)
    first.ruler.pointerMoved(toY: nil)
    #expect(told == [0, nil], "once on, once off: \(told)")
}
