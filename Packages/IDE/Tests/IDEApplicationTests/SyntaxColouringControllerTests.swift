import Foundation
import IDEApplication
import IDEDomain
import IDETestSupport
import Testing

/// What stands for the presenter: it only has to live while colours are shown, and say when it goes.
private final class Shown: @unchecked Sendable {
    final class Token {
        let shown: Shown
        init(_ shown: Shown) { self.shown = shown; shown.made += 1 }
        deinit { shown.released += 1 }
    }
    var made = 0
    var released = 0
    func token() -> Token { Token(self) }
}

@MainActor
private struct Setup {
    let backend: StringDocumentBackend
    let session: DocumentSession
    let controller: SyntaxColouringController
    let highlighters: Highlighters
    let shown: Shown
    let states: States

    @MainActor final class Highlighters { var all: [ScriptedHighlighter] = []; var available = true }
    @MainActor final class States { var seen: [SyntaxColouringController.State] = [] }

    /// A limit of 1000 units makes "large" easy to reach; 900 is where colouring resumes.
    init(path: String = "Main.swift", text: String = String(repeating: "x", count: 100), limit: Int = 1_000) {
        backend = StringDocumentBackend(loadedText: text)
        session = DocumentSession(path: path, backend: backend)
        let highlighters = Highlighters()
        let shown = Shown()
        self.highlighters = highlighters
        self.shown = shown
        let states = States()
        self.states = states
        controller = SyntaxColouringController(
            session: session, source: backend,
            policy: SyntaxPolicy(maximumDocumentLength: limit),
            makeHighlighter: {
                guard highlighters.available else { return nil }
                let highlighter = ScriptedHighlighter()
                highlighters.all.append(highlighter)
                return highlighter
            },
            present: { _ in shown.token() }
        )
        controller.onChange = { states.seen.append($0) }
    }

    func replace(_ range: Range<Int>, with text: String) throws {
        try session.apply(
            [DocumentEdit(range: UTF16TextRange(location: range.lowerBound, length: range.count), replacement: text)],
            expectedVersion: session.version
        )
    }
}

// MARK: Size changes after the window is open (review P1)

@Test @MainActor
func aSwiftFileUnderTheLimitIsColouredFromTheStart() {
    let s = Setup()
    #expect(s.controller.state == .on)
    #expect(s.highlighters.all.count == 1 && s.shown.made == 1)
}

@Test @MainActor
func aSmallFileThatGrowsPastTheLimitStopsBeingColouredAndLetsGoOfEverything() throws {
    let s = Setup()
    try s.replace(100..<100, with: String(repeating: "y", count: 2_000))

    #expect(s.controller.state == .off(.tooLarge))
    #expect(s.highlighters.all[0].calls.contains(.stop), "the parser is told to stop and drop its tree and text")
    #expect(s.shown.released == 1, "the presenter is gone, so its colours are cleared")
    #expect(s.states.seen == [.off(.tooLarge)])
}

@Test @MainActor
func theHighlighterNeverSeesTheEditThatMadeTheFileTooLarge() throws {
    // Handing a multi-megabyte paste to the parser first and stopping it afterwards would parse it.
    let s = Setup()
    s.highlighters.all[0].clearCalls()
    try s.replace(100..<100, with: String(repeating: "y", count: 2_000))
    #expect(s.highlighters.all[0].calls == [.stop])
}

@Test @MainActor
func nothingIsSentToAHighlighterWhileTheFileStaysTooLarge() throws {
    let s = Setup()
    try s.replace(100..<100, with: String(repeating: "y", count: 2_000))
    let calls = s.highlighters.all[0].calls
    try s.replace(0..<0, with: "more")
    try s.replace(5..<9, with: "")
    #expect(s.highlighters.all[0].calls == calls)
    #expect(s.highlighters.all.count == 1)
}

@Test @MainActor
func aFileThatOpensTooLargeIsNeverGivenAHighlighter() {
    let s = Setup(text: String(repeating: "x", count: 5_000))
    #expect(s.controller.state == .off(.tooLarge))
    #expect(s.highlighters.all.isEmpty && s.shown.made == 0)
}

@Test @MainActor
func colouringComesBackOnceTheFileIsComfortablyUnderTheLimit() throws {
    let s = Setup()
    try s.replace(100..<100, with: String(repeating: "y", count: 2_000))
    try s.replace(100..<2_000, with: "")   // 200 units left
    #expect(s.controller.state == .on)
    #expect(s.highlighters.all.count == 2, "a fresh highlighter, not the one that was stopped")
    #expect(s.highlighters.all[1].calls.first == .reset(units: 200, version: 2))
    #expect(s.states.seen == [.off(.tooLarge), .on])
}

@Test @MainActor
func aFileHoveringJustUnderTheLimitDoesNotSwitchColouringBackAndForth() throws {
    let s = Setup()
    try s.replace(100..<100, with: String(repeating: "y", count: 2_000))     // 2100: off
    try s.replace(950..<2_100, with: "")                                     // 950: under the limit, above 900
    #expect(s.controller.state == .off(.tooLarge))
    try s.replace(900..<950, with: "")                                       // 900: resumes
    #expect(s.controller.state == .on)
}

@Test @MainActor
func aFileThatGrewOnDiskAndWasReloadedStopsBeingColoured() async throws {
    let store = MemoryDocumentFileStore(contents: ["/w/Main.swift": String(repeating: "x", count: 100)])
    let registry = DocumentRegistry()
    let open = OpenDocumentUseCase(store: store, registry: registry) { file in
        DocumentSession(loaded: file, backend: StringDocumentBackend(loadedText: file.text))
    }
    let session = try await open.execute(path: "/w/Main.swift").session
    let shown = Shown()
    let controller = SyntaxColouringController(
        session: session, source: StringDocumentBackend(loadedText: session.text),
        policy: SyntaxPolicy(maximumDocumentLength: 1_000),
        makeHighlighter: { ScriptedHighlighter() },
        present: { _ in shown.token() }
    )
    #expect(controller.state == .on)

    await store.externallyWrite(String(repeating: "z", count: 5_000), at: "/w/Main.swift")
    try await ReloadDocumentUseCase(store: store).execute(document: session)

    #expect(controller.state == .off(.tooLarge))
    #expect(shown.released == 1)
}

// MARK: Save As changes the language (review P2)

@Test @MainActor
func savingATextFileAsSwiftStartsColouring() async throws {
    let store = MemoryDocumentFileStore(contents: ["/w/Notes.txt": "let a = 1"])
    let registry = DocumentRegistry()
    let open = OpenDocumentUseCase(store: store, registry: registry) { file in
        DocumentSession(loaded: file, backend: StringDocumentBackend(loadedText: file.text))
    }
    let session = try await open.execute(path: "/w/Notes.txt").session
    let backend = StringDocumentBackend(loadedText: session.text)
    let shown = Shown()
    let controller = SyntaxColouringController(
        session: session, source: backend, policy: .standard,
        makeHighlighter: { ScriptedHighlighter() },
        present: { _ in shown.token() }
    )
    #expect(controller.state == .off(.languageNotSupported))

    _ = try await SaveDocumentUseCase(store: store).saveAs(
        document: session, to: "/w/Notes.swift", target: .newFile, registry: registry
    )
    controller.refresh()

    #expect(controller.state == .on)
    #expect(shown.made == 1)
}

@Test @MainActor
func savingASwiftFileAsTextStopsColouring() async throws {
    let store = MemoryDocumentFileStore(contents: ["/w/Main.swift": "let a = 1"])
    let registry = DocumentRegistry()
    let open = OpenDocumentUseCase(store: store, registry: registry) { file in
        DocumentSession(loaded: file, backend: StringDocumentBackend(loadedText: file.text))
    }
    let session = try await open.execute(path: "/w/Main.swift").session
    let shown = Shown()
    let highlighter = ScriptedHighlighter()
    let controller = SyntaxColouringController(
        session: session, source: StringDocumentBackend(loadedText: session.text), policy: .standard,
        makeHighlighter: { highlighter },
        present: { _ in shown.token() }
    )
    #expect(controller.state == .on)

    _ = try await SaveDocumentUseCase(store: store).saveAs(
        document: session, to: "/w/Main.txt", target: .newFile, registry: registry
    )
    controller.refresh()

    #expect(controller.state == .off(.languageNotSupported))
    #expect(highlighter.calls.contains(.stop))
    #expect(shown.released == 1)
}

@Test @MainActor
func aHighlighterThatCannotBeMadeLeavesTheFilePlainAndSaysSo() {
    let backend = StringDocumentBackend(loadedText: "let a = 1")
    let session = DocumentSession(path: "Main.swift", backend: backend)
    let controller = SyntaxColouringController(
        session: session, source: backend, policy: .standard,
        makeHighlighter: { nil }, present: { _ in nil }
    )
    #expect(controller.state == .off(.unavailable))
}

// MARK: Order of observers

@Test @MainActor
func observersOfAChangeAreCalledInTheOrderTheySubscribed() throws {
    let session = DocumentSession(path: "A.swift", backend: StringDocumentBackend(loadedText: "abc"))
    var order: [Int] = []
    for index in 0..<20 { session.subscribeToChanges { _ in order.append(index) } }
    try session.replaceText("abcd", expectedVersion: 0)
    #expect(order == Array(0..<20))
}

@Test @MainActor
func anObserverThatUnsubscribesAnotherDuringACallStopsItFromBeingCalled() throws {
    let session = DocumentSession(path: "A.swift", backend: StringDocumentBackend(loadedText: "abc"))
    var second = 0
    var secondID: UUID?
    session.subscribeToChanges { _ in if let secondID { session.unsubscribeFromChanges(secondID) } }
    secondID = session.subscribeToChanges { _ in second += 1 }
    try session.replaceText("abcd", expectedVersion: 0)
    #expect(second == 0)
}

// MARK: The document's language decides

@MainActor
private func controller(path: String, supported: Set<DocumentLanguage> = [.swift]) -> (SyntaxColouringController, DocumentLanguageSelector, DocumentSession, Shown, ScriptedHighlighterBox) {
    let backend = StringDocumentBackend(loadedText: "let a = 1")
    let session = DocumentSession(path: path, backend: backend)
    let selector = DocumentLanguageSelector(session: session)
    let shown = Shown()
    let box = ScriptedHighlighterBox()
    let colouring = SyntaxColouringController(
        session: session, source: backend, policy: .standard, languages: selector, supportedLanguages: supported,
        makeHighlighter: { box.make() }, present: { _ in shown.token() }
    )
    return (colouring, selector, session, shown, box)
}

@MainActor
private final class ScriptedHighlighterBox {
    var made: [ScriptedHighlighter] = []
    func make() -> ScriptedHighlighter { let h = ScriptedHighlighter(); made.append(h); return h }
}

@Test @MainActor
func chosenAsPlainTextASwiftFileLosesItsColoursAndGetsThemBack() {
    let (colouring, selector, session, shown, box) = controller(path: "/w/Main.swift")
    #expect(colouring.state == .on && shown.made == 1)
    let (text, version) = (session.text, session.version)

    selector.setOverride(.plainText)
    #expect(colouring.state == .off(.languageNotSupported))
    #expect(shown.released == 1 && box.made[0].calls.contains(.stop), "the old colours are gone, not left on the text")
    #expect(session.text == text && session.version == version && !session.isDirty)

    selector.setOverride(nil)
    #expect(colouring.state == .on && shown.made == 2 && box.made.count == 2, "a fresh start, not the old tree")
}

@Test @MainActor
func aTextFileChosenAsSwiftGetsColours() {
    let (colouring, selector, _, shown, _) = controller(path: "/w/notes.txt")
    #expect(colouring.state == .off(.languageNotSupported))
    selector.setOverride(.swift)
    #expect(colouring.state == .on && shown.made == 1)
}

@Test @MainActor
func fromOneColouredLanguageToAnotherTheColoursAreMadeAgain() {
    let (colouring, selector, _, shown, box) = controller(path: "/w/a.c", supported: [.c, .cpp])
    #expect(colouring.state == .on)
    selector.setOverride(.cpp)
    #expect(colouring.state == .on)
    #expect(shown.made == 2 && shown.released == 1 && box.made[0].calls.contains(.stop), "not the colours made for C")
}

@Test @MainActor
func confirmingTheLanguageTheNameSaidChangesNothing() {
    let (colouring, selector, _, shown, _) = controller(path: "/w/Main.swift")
    selector.setOverride(.swift)
    #expect(colouring.state == .on && shown.made == 1 && shown.released == 0)
}

@Test @MainActor
func aLanguageWithoutGrammarHasNoColoursYetItIsNotAFailure() {
    let (colouring, _, _, shown, _) = controller(path: "/w/a.cpp")
    #expect(colouring.state == .off(.languageNotSupported) && shown.made == 0)
}

@Test @MainActor
func theHighlighterIsMadeForTheLanguageOfTheDocument() {
    let backend = StringDocumentBackend(loadedText: "int a;")
    let session = DocumentSession(path: "/w/a.c", backend: backend)
    let selector = DocumentLanguageSelector(session: session)
    var asked: [DocumentLanguage] = []
    let colouring = SyntaxColouringController(
        session: session, source: backend, languages: selector, supportedLanguages: [.c, .cpp, .swift],
        makeHighlighter: { language in asked.append(language); return ScriptedHighlighter() },
        present: { _ in Shown().token() }
    )
    #expect(asked == [.c] && colouring.state == .on)
    selector.setOverride(.cpp)
    selector.setOverride(.objectiveCPP)        // no grammar: nothing is made
    selector.setOverride(.swift)
    #expect(asked == [.c, .cpp, .swift])
    #expect(colouring.state == .on)
}
