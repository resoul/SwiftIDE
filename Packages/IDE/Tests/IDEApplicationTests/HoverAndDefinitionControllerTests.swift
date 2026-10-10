import Foundation
import IDEApplication
import IDEDomain
import IDETestSupport
import Testing

@MainActor
private final class FakeHover: HoverProviding {
    private(set) var asked: [Int] = []
    var answer: (Int) async -> HoverOutcome = { _ in .content(HoverContent(text: "a function")) }

    func hover(for session: DocumentSession, offset: @MainActor () -> Int) async -> HoverOutcome {
        asked.append(offset())

        return await answer(asked.count)
    }
}

@MainActor
private final class FakeHoverView: HoverPresenting {
    private(set) var shown: [(text: String, anchor: UTF16TextRange)] = []
    private(set) var dismissals = 0
    var isVisible = false

    func show(_ text: String, anchor: UTF16TextRange) {
        shown.append((text, anchor))
        isVisible = true
    }

    func dismiss() {
        dismissals += 1
        isVisible = false
    }
}

@MainActor
private struct Rig {
    // "let value = compute(1)\n": value 4..<9, compute 12..<19
    let session = DocumentSession(path: "/w/A.swift", backend: StringDocumentBackend(loadedText: "let value = compute(1)\n"))
    let provider = FakeHover()
    let view = FakeHoverView()
    let clock = ManualDelayClock()
    let controller: HoverController
    var local: [Int: [String]] = [:]

    init(local: [Int: [String]] = [:]) {
        let words = [UTF16TextRange(location: 0, length: 3), UTF16TextRange(location: 4, length: 5), UTF16TextRange(location: 12, length: 7)]
        controller = HoverController(
            session: session,
            provider: provider,
            presenter: view,
            clock: clock,
            wordAt: { offset in words.first { offset >= $0.location && offset < $0.location + $0.length } },
            localMessages: { local[$0] ?? [] }
        )
    }

    func settle() async {
        for _ in 0..<40 { await Task.yield() }
    }

    func rest(at offset: Int) async {
        controller.pointerMoved(to: offset)
        await settle()
        clock.advance(by: .milliseconds(500))
        await settle()
    }
}

// MARK: Hover

@Test @MainActor
func aPointerThatRestsOnAWordGetsItsDescriptionUnderIt() async {
    let rig = Rig()
    rig.controller.pointerMoved(to: 13)
    await rig.settle()
    rig.clock.advance(by: .milliseconds(499))
    await rig.settle()
    #expect(rig.provider.asked.isEmpty && !rig.view.isVisible, "not before the pointer has rested")
    rig.clock.advance(by: .milliseconds(1))
    await rig.settle()
    #expect(rig.provider.asked == [12], "asked at the start of the word, not where the pointer is")
    #expect(rig.view.shown.last?.text == "a function" && rig.view.shown.last?.anchor == UTF16TextRange(location: 12, length: 7))
    #expect(rig.controller.isShowing)
}

@Test @MainActor
func movingOnWithinTheWordChangesNothingAndToAnotherWordStartsOver() async {
    let rig = Rig()
    await rig.rest(at: 13)
    rig.controller.pointerMoved(to: 15)
    await rig.settle()
    #expect(rig.view.dismissals == 0 && rig.provider.asked.count == 1, "same word: the description stays, nothing is asked again")

    rig.controller.pointerMoved(to: 5)
    await rig.settle()
    #expect(!rig.view.isVisible, "gone at once on another word")
    rig.clock.advance(by: .milliseconds(500))
    await rig.settle()
    #expect(rig.provider.asked == [12, 4])
}

@Test @MainActor
func leavingTheTextOrAWhitespaceTakesTheDescriptionAndWaitingAway() async {
    let rig = Rig()
    await rig.rest(at: 13)
    rig.controller.pointerMoved(to: nil)
    #expect(!rig.view.isVisible && !rig.controller.isShowing)

    rig.controller.pointerMoved(to: 5)
    rig.controller.pointerMoved(to: 10)         // a space between words
    await rig.settle()
    rig.clock.advance(by: .seconds(2))
    await rig.settle()
    #expect(rig.provider.asked.count == 1, "the wait for the first word was given up")
}

@Test @MainActor
func anEditOrMarkedTextTakesTheDescriptionAway() async throws {
    let rig = Rig()
    await rig.rest(at: 13)
    #expect(rig.view.isVisible)
    try rig.session.apply([DocumentEdit(range: UTF16TextRange(location: 0, length: 0), replacement: "x")], expectedVersion: rig.session.version, origin: .typing)
    #expect(!rig.view.isVisible)

    await rig.rest(at: 14)
    #expect(rig.view.isVisible)
    rig.session.compositionDidChange(.began)
    #expect(!rig.view.isVisible)
    rig.session.compositionDidChange(.ended)
}

@Test @MainActor
func ADescriptionThatArrivesAfterThePointerMovedOnIsNotShown() async {
    let rig = Rig()
    var release: CheckedContinuation<Void, Never>?
    rig.provider.answer = { _ in
        await withCheckedContinuation { release = $0 }

        return .content(HoverContent(text: "late"))
    }
    rig.controller.pointerMoved(to: 13)
    await rig.settle()
    rig.clock.advance(by: .milliseconds(500))
    await rig.settle()
    rig.controller.pointerMoved(to: nil)
    release?.resume()
    await rig.settle()
    #expect(rig.view.shown.isEmpty)
}

@Test @MainActor
func theServersRangeIsWhatTheDescriptionIsAnchoredToAndKeepsItWhilethePointerIsOverIt() async {
    let rig = Rig()
    rig.provider.answer = { _ in .content(HoverContent(text: "the call", range: UTF16TextRange(location: 12, length: 10))) }
    await rig.rest(at: 13)
    #expect(rig.view.shown.last?.anchor == UTF16TextRange(location: 12, length: 10))
    rig.controller.pointerMoved(to: 21)          // beyond the word, inside the described text
    await rig.settle()
    #expect(rig.view.dismissals == 0 && rig.provider.asked.count == 1)
}

@Test @MainActor
func theProblemsHereAreShownAtOnceAndTheServersWordsAreAddedBelow() async {
    let rig = Rig(local: [12: ["error: cannot find 'compute'"]])
    var release: CheckedContinuation<Void, Never>?
    rig.provider.answer = { _ in
        await withCheckedContinuation { release = $0 }

        return .content(HoverContent(text: "func compute()"))
    }
    await rig.rest(at: 13)
    #expect(rig.view.shown.map(\.text) == ["error: cannot find 'compute'"], "without waiting for the server")
    release?.resume()
    await rig.settle()
    #expect(rig.view.shown.last?.text == "error: cannot find 'compute'\n\nfunc compute()")
}

@Test @MainActor
func whenTheServerHasNothingByPointerNothingIsShownAndByKeyTheUserIsToldWhy() async {
    for outcome in [HoverOutcome.nothing, .failed(.unavailable(.starting)), .failed(.unavailable(.failed("x")))] {
        let rig = Rig()
        rig.provider.answer = { _ in outcome }
        await rig.rest(at: 13)
        #expect(rig.view.shown.isEmpty, "\(outcome): silent by pointer")

        rig.controller.requestAtCaret(13)
        await rig.settle()
        #expect(rig.view.shown.count == 1 && !rig.view.shown[0].text.isEmpty, "\(outcome): said by key")
    }
}

@Test @MainActor
func byKeyTheDescriptionIsAskedForAtOnceAtTheWordOfTheCaret() async {
    let rig = Rig()
    rig.controller.requestAtCaret(5)
    await rig.settle()
    #expect(rig.provider.asked == [4] && rig.view.shown.last?.anchor == UTF16TextRange(location: 4, length: 5), "no waiting")
}

@Test @MainActor
func aStaleOrSuppressedAnswerIsSilentEvenByKey() async {
    for outcome in [HoverOutcome.failed(.stale(.documentChanged)), .failed(.suppressedByComposition)] {
        let rig = Rig()
        rig.provider.answer = { _ in outcome }
        rig.controller.requestAtCaret(5)
        await rig.settle()
        #expect(rig.view.shown.isEmpty)
    }
}

@Test @MainActor
func byKeyDuringCompositionAsksNothing() async {
    let rig = Rig()
    rig.session.compositionDidChange(.began)
    rig.controller.requestAtCaret(5)
    await rig.settle()
    #expect(rig.provider.asked.isEmpty)
    rig.session.compositionDidChange(.ended)
}

// MARK: Definition

@MainActor
private final class FakeDefinitions: DefinitionProviding {
    var answer: DefinitionOutcome = .nothing
    var gate: CheckedContinuation<Void, Never>?
    var hold = false
    private(set) var asked: [Int] = []

    func definition(for session: DocumentSession, offset: @MainActor () -> Int) async -> DefinitionOutcome {
        asked.append(offset())
        if hold { await withCheckedContinuation { gate = $0 } }

        return answer
    }
}

@MainActor
private final class FakeNavigator: DefinitionNavigating {
    private(set) var events: [String] = []
    func moveCaret(to offset: Int) { events.append("caret \(offset)") }
    func open(_ location: DefinitionLocation) { events.append("open \(location.path):\(location.line):\(location.character)") }
    func tell(_ message: String, at offset: Int) { events.append("tell \(message) @\(offset)") }
}

@MainActor
private func jump(_ answer: DefinitionOutcome) async -> [String] {
    let session = DocumentSession(path: "/w/A.swift", backend: StringDocumentBackend(loadedText: "x"))
    let provider = FakeDefinitions()
    provider.answer = answer
    let navigator = FakeNavigator()
    await DefinitionController(session: session, provider: provider, navigator: navigator).jump(from: 7)

    return navigator.events
}

@Test @MainActor
func aDefinitionInThisDocumentMovesTheCaretAndInAnotherFileOpensIt() async {
    #expect(await jump(.locations([DefinitionLocation(path: "/w/A.swift", line: 0, character: 4, offset: 4)])) == ["caret 4"])
    #expect(await jump(.locations([DefinitionLocation(path: "/w/B.swift", line: 3, character: 2)])) == ["open /w/B.swift:3:2"])
}

@Test @MainActor
func severalDefinitionsOpenTheFirstAndSaySo() async {
    let events = await jump(.locations([DefinitionLocation(path: "/w/B.swift", line: 1, character: 0), DefinitionLocation(path: "/w/C.swift", line: 2, character: 0)]))
    #expect(events == ["open /w/B.swift:1:0", "tell 1 of 2 definitions @7"])
}

@Test @MainActor
func noDefinitionAnUnavailableServerAndAStaleAnswerAreToldOrLeftSilent() async {
    #expect(await jump(.nothing) == ["tell No definition found @7"])
    #expect(await jump(.locations([])) == ["tell No definition found @7"])
    #expect(await jump(.failed(.unavailable(.starting))) == ["tell SourceKit is starting… @7"])
    #expect(await jump(.failed(.unavailable(.notRunning))) == ["tell SourceKit is not available @7"])
    #expect(await jump(.failed(.stale(.documentChanged))).isEmpty)
    #expect(await jump(.failed(.suppressedByComposition)).isEmpty)
}

@Test @MainActor
func aNewerJumpReplacesAnOlderOneStillWaiting() async {
    let session = DocumentSession(path: "/w/A.swift", backend: StringDocumentBackend(loadedText: "x"))
    let provider = FakeDefinitions()
    provider.hold = true
    provider.answer = .locations([DefinitionLocation(path: "/w/Old.swift", line: 0, character: 0)])
    let navigator = FakeNavigator()
    let controller = DefinitionController(session: session, provider: provider, navigator: navigator)
    let first = Task { @MainActor in await controller.jump(from: 1) }
    for _ in 0..<40 { await Task.yield() }
    let older = provider.gate
    provider.gate = nil
    provider.hold = false
    provider.answer = .locations([DefinitionLocation(path: "/w/New.swift", line: 0, character: 0)])
    await controller.jump(from: 2)
    older?.resume()
    await first.value
    #expect(navigator.events == ["open /w/New.swift:0:0"])
}

@Test @MainActor
func movingWithinTheWordWhileWaitingDoesNotRestartTheWait() async {
    let rig = Rig()
    rig.controller.pointerMoved(to: 13)
    await rig.settle()
    rig.clock.advance(by: .milliseconds(300))
    await rig.settle()
    rig.controller.pointerMoved(to: 15)
    await rig.settle()
    rig.clock.advance(by: .milliseconds(200))
    await rig.settle()
    #expect(rig.provider.asked == [12], "half a second after the pointer came to the word")
}
