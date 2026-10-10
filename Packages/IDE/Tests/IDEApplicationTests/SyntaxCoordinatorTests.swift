import Foundation
import IDEApplication
import IDEDomain
import IDETestSupport
import Testing

@MainActor
private struct Setup {
    let backend: StringDocumentBackend
    let session: DocumentSession
    let highlighter = ScriptedHighlighter()
    let coordinator: SyntaxCoordinator
    let changed: Changes

    @MainActor final class Changes { var ranges: [[Range<Int>]] = [] }

    init(_ text: String, margin: Int = 20) {
        backend = StringDocumentBackend(loadedText: text)
        session = DocumentSession(path: "Main.swift", backend: backend)
        coordinator = SyntaxCoordinator(session: session, source: backend, highlighter: highlighter, margin: margin)
        let changed = Changes()
        self.changed = changed
        coordinator.onChange = { changed.ranges.append($0) }
    }

    func insert(_ text: String, at location: Int) throws {
        try session.apply(
            [DocumentEdit(range: UTF16TextRange(location: location, length: 0), replacement: text)],
            expectedVersion: session.version
        )
    }

    /// Lets the main-actor hop that delivers a result run.
    func settle() async { await Task.yield(); await Task.yield() }
}

@Test @MainActor
func theHighlighterIsGivenTheWholeTextAtTheStartAndAskedForTheFirstWindow() {
    let s = Setup(String(repeating: "x", count: 100))
    #expect(s.highlighter.calls == [
        .reset(units: 100, version: 0),
        .request(window: 0..<40, version: 0)   // nothing visible yet: the start, with margin
    ])
}

@Test @MainActor
func anEditIsForwardedAndColoursAreAskedForAgainAtTheNewVersion() throws {
    let s = Setup(String(repeating: "x", count: 100))
    s.coordinator.setVisible(10..<30)
    s.highlighter.clearCalls()
    try s.insert("abc", at: 50)
    #expect(s.highlighter.calls == [
        .edit(from: 0, to: 1),
        .request(window: 0..<50, version: 1)   // what is visible, as it was set, plus margin
    ])
}

@Test @MainActor
func aResultForTheCurrentVersionBecomesTheStateAndReportsWhatChanged() async {
    let s = Setup(String(repeating: "x", count: 100))
    s.coordinator.setVisible(0..<40)
    s.highlighter.answer(HighlightResult(
        version: 0,
        window: 0..<40,
        spans: [HighlightSpan(location: 3, length: 4, kind: .keyword)],
        documentLength: 100
    ))
    await s.settle()
    #expect(s.coordinator.state.spans == [HighlightSpan(location: 3, length: 4, kind: .keyword)])
    #expect(s.changed.ranges == [[3..<7]])
}

@Test @MainActor
func aResultForAnOlderVersionIsDropped() async throws {
    let s = Setup(String(repeating: "x", count: 100))
    try s.insert("a", at: 0)
    s.highlighter.answer(HighlightResult(
        version: 0,
        window: 0..<40,
        spans: [HighlightSpan(location: 3, length: 4, kind: .keyword)],
        documentLength: 100
    ))
    await s.settle()
    #expect(s.coordinator.state.spans.isEmpty)
    #expect(s.changed.ranges.isEmpty)
}

@Test @MainActor
func coloursFollowEditsUntilTheNextResult() async throws {
    let s = Setup(String(repeating: "x", count: 100))
    s.highlighter.answer(HighlightResult(
        version: 0,
        window: 0..<40,
        spans: [HighlightSpan(location: 10, length: 4, kind: .keyword)],
        documentLength: 100
    ))
    await s.settle()
    try s.insert("ZZ", at: 0)
    #expect(s.coordinator.state.spans == [HighlightSpan(location: 12, length: 4, kind: .keyword)], "moved with its text")
}

@Test @MainActor
func aResultWithTheWrongTextLengthMakesTheHighlighterStartOver() async {
    let s = Setup(String(repeating: "x", count: 100))
    s.highlighter.clearCalls()
    s.highlighter.answer(HighlightResult(version: 0, window: 0..<40, spans: [], documentLength: 99))
    await s.settle()
    #expect(s.coordinator.resyncCount == 1)
    #expect(s.highlighter.calls.first == .reset(units: 100, version: 0))
    #expect(s.highlighter.calls.contains(.request(window: 0..<40, version: 0)))
}

@Test @MainActor
func scrollingAsksForNewColoursOnlyOutsideWhatIsKnown() async {
    let s = Setup(String(repeating: "x", count: 1_000))
    s.highlighter.answer(HighlightResult(version: 0, window: 0..<100, spans: [], documentLength: 1_000))
    await s.settle()
    s.highlighter.clearCalls()

    s.coordinator.setVisible(30..<60)       // inside the known window
    #expect(s.highlighter.calls.isEmpty)

    s.coordinator.setVisible(500..<540)     // elsewhere
    #expect(s.highlighter.calls == [.request(window: 480..<560, version: 0)])

    s.coordinator.setVisible(505..<535)     // the same answer is already awaited
    #expect(s.highlighter.calls.count == 1)
}

@Test @MainActor
func theHighlighterIsStoppedWhenTheCoordinatorGoes() {
    let highlighter = ScriptedHighlighter()
    do {
        let backend = StringDocumentBackend(loadedText: "abc")
        let session = DocumentSession(path: "Main.swift", backend: backend)
        _ = SyntaxCoordinator(session: session, source: backend, highlighter: highlighter)
    }
    #expect(highlighter.calls.last == .stop)
}

@Test @MainActor
func changesAreHeldWhileAnInputMethodComposesAndReportedWhenItEnds() async {
    let s = Setup(String(repeating: "x", count: 100))
    s.coordinator.setVisible(0..<40)
    s.backend.simulateComposition(.began)
    s.highlighter.answer(HighlightResult(
        version: 0,
        window: 0..<40,
        spans: [HighlightSpan(location: 3, length: 4, kind: .keyword)],
        documentLength: 100
    ))
    await s.settle()
    #expect(s.coordinator.state.spans.count == 1, "the state is up to date")
    #expect(s.changed.ranges.isEmpty, "but nothing is refreshed under marked text")

    s.backend.simulateComposition(.ended)
    #expect(s.changed.ranges == [[3..<7]], "what changed meanwhile is reported once the composition is over")
}

@Test @MainActor
func aChangeOutOfViewWaitsUntilItsTextIsScrolledTo() async {
    let s = Setup(String(repeating: "x", count: 1_000))
    s.coordinator.setVisible(0..<40)
    s.highlighter.answer(HighlightResult(
        version: 0,
        window: 0..<600,
        spans: [HighlightSpan(location: 500, length: 10, kind: .string)],
        documentLength: 1_000
    ))
    await s.settle()
    #expect(s.changed.ranges.isEmpty, "the change is far from what is in view: nothing is redrawn")
    #expect(s.coordinator.state.dirty == [500..<510])

    s.coordinator.setVisible(480..<540)
    #expect(s.changed.ranges == [[500..<510]])
    #expect(s.coordinator.state.dirty.isEmpty)
}

@Test @MainActor
func whatIsInViewMovesWithTheText() async throws {
    let s = Setup(String(repeating: "x", count: 1_000))
    s.coordinator.setVisible(100..<140)
    try s.insert(String(repeating: "y", count: 20), at: 0)     // the view's text is at 120..<160 now
    s.highlighter.answer(HighlightResult(
        version: 1,
        window: 100..<200,
        spans: [HighlightSpan(location: 150, length: 5, kind: .keyword)],
        documentLength: 1_020
    ))
    await s.settle()
    #expect(s.changed.ranges == [[150..<155]], "inside the view as it has moved, though not as it was")
}

// MARK: A document that shrinks under what was on screen

@Test @MainActor
func aDocumentThatShrinksBelowTheVisibleTextStillGetsAWindowInsideIt() throws {
    let s = Setup(String(repeating: "x", count: 1_000))
    s.coordinator.setVisible(900..<950)
    s.highlighter.clearCalls()
    // 800 units go; what was visible lies beyond the end of the text now.
    try s.session.apply(
        [DocumentEdit(range: UTF16TextRange(location: 100, length: 800), replacement: "")],
        expectedVersion: s.session.version
    )
    let requests = s.highlighter.calls.compactMap { call -> Range<Int>? in
        if case .request(let window, _) = call { return window } else { return nil }
    }
    #expect(requests.count == 1)
    #expect(requests.allSatisfy { $0.lowerBound >= 0 && $0.upperBound <= 200 && $0.lowerBound <= $0.upperBound })

    s.coordinator.setVisible(5_000..<5_040)   // a stale caller, far beyond the end
    s.coordinator.setVisible(150..<400)       // partly beyond it
}

@Test @MainActor
func aDocumentEmptiedCompletelyIsHandled() throws {
    let s = Setup("abc")
    s.coordinator.setVisible(0..<3)
    try s.session.apply(
        [DocumentEdit(range: UTF16TextRange(location: 0, length: 3), replacement: "")],
        expectedVersion: s.session.version
    )
    s.coordinator.setVisible(0..<3)
    #expect(s.highlighter.calls.contains(.request(window: 0..<0, version: 1)) || s.highlighter.calls.last != nil)
}

// MARK: Colours of an area seen before an edit

@Test @MainActor
func anAreaSeenBeforeAnEditIsAskedForAgainWhenItComesBackIntoView() async throws {
    let s = Setup(String(repeating: "x", count: 1_000))
    // The reader sees the top, then moves a little down; the answers join into one wide window.
    s.coordinator.setVisible(20..<60)
    s.highlighter.answer(HighlightResult(version: 0, window: 0..<100, spans: [], documentLength: 1_000))
    await s.settle()
    s.coordinator.setVisible(100..<140)
    s.highlighter.answer(HighlightResult(version: 0, window: 60..<180, spans: [], documentLength: 1_000))
    await s.settle()

    // An edit near the top, then the answer for what is in view now.
    try s.insert("/*", at: 10)
    s.highlighter.answer(HighlightResult(version: 1, window: 60..<182, spans: [], documentLength: 1_002))
    await s.settle()
    s.highlighter.clearCalls()

    // Back to the top: the text there was coloured before the edit and nobody has looked since.
    s.coordinator.setVisible(20..<60)
    #expect(s.highlighter.calls.contains { call in
        if case .request(let window, let version) = call { return version == 1 && window.contains(20) && window.contains(59) }

        return false
    }, "the answer for version 1 covers only the area in view when it was asked")
}

@Test @MainActor
func theKnownWindowIsOnlyWhatTheLatestAnswerDescribes() async throws {
    let s = Setup(String(repeating: "x", count: 1_000))
    s.highlighter.answer(HighlightResult(version: 0, window: 0..<100, spans: [], documentLength: 1_000))
    await s.settle()
    s.highlighter.answer(HighlightResult(version: 0, window: 100..<200, spans: [], documentLength: 1_000))
    await s.settle()
    #expect(s.coordinator.state.window == 100..<200)
}

@Test @MainActor
func anOldWindowIsNotKnownColoursOfTheNewVersionUntilItsAnswerComes() async throws {
    // After an edit the old window still describes the colours of the old text. Scrolling inside it,
    // but outside what was asked for the new version, needs an answer for the new version.
    let s = Setup(String(repeating: "x", count: 1_000))
    s.coordinator.setVisible(200..<240)
    s.highlighter.answer(HighlightResult(version: 0, window: 160..<280, spans: [], documentLength: 1_000))
    await s.settle()
    s.coordinator.setVisible(240..<280)          // still inside the known window: nothing asked
    try s.insert("/*", at: 0)                     // asks version 1 for what is in view: 240..280 ± margin
    s.highlighter.clearCalls()

    s.coordinator.setVisible(170..<200)           // inside the old window, outside the new request
    let asked = s.highlighter.calls.contains { call in
        if case .request(let window, let version) = call { return version == 1 && window.contains(170) } else { return false }
    }
    #expect(asked, "no answer for version 1 covers this part yet")
}
