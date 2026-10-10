import Foundation
@testable import IDEApplication
import IDEDomain
import IDETestSupport
import Testing

@MainActor
private final class FakeProvider: CompletionProviding {
    struct Call { let version: UInt64; let caret: Int }
    private(set) var calls: [Call] = []
    var answer: (Int) async -> CompletionOutcome = { _ in .items([], isIncomplete: false) }

    func completion(for session: DocumentSession, caret: @MainActor () -> Int) async -> CompletionOutcome {
        calls.append(Call(version: session.version, caret: caret()))
        return await answer(calls.count)
    }
}

@MainActor
private final class FakePresenter: CompletionPresenting {
    struct Shown: Equatable { let labels: [String]; let selected: Int; let anchor: Int }
    private(set) var shown: [Shown] = []
    private(set) var selections: [Int] = []
    private(set) var dismissals = 0
    private(set) var statuses: [CompletionStatus] = []
    var isVisible = false

    func present(rows: [CompletionRow], selected: Int, anchorOffset: Int) {
        shown.append(Shown(labels: rows.map(\.label), selected: selected, anchor: anchorOffset))
        isVisible = true
    }
    func select(_ index: Int) { selections.append(index) }
    func dismiss() { dismissals += 1; isVisible = false }
    func showStatus(_ status: CompletionStatus, anchorOffset: Int) { statuses.append(status); isVisible = true }
}

private func item(_ label: String, insert: String? = nil, filter: String? = nil, sort: String? = nil, kind: CompletionKind = .method) -> CompletionItem {
    CompletionItem(label: label, detail: "T", insertText: insert ?? label, sortText: sort ?? label, filterText: filter ?? label, kind: kind)
}

private let members: [CompletionItem] = [
    item("count", kind: .property),
    item("hasPrefix(prefix: String)", insert: "hasPrefix()", filter: "hasPrefix(:)"),
    item("append(contentsOf: String)", insert: "append(contentsOf: )", filter: "append(contentsOf:)"),
    item("uppercased()"),
    item("Array", kind: .type),
]

@MainActor
private final class Rig {
    let provider = FakeProvider()
    let presenter = FakePresenter()
    let session: DocumentSession
    var caret: Int
    var hasCaret = true
    var carets: [Int] = []
    let controller: CompletionController
    let clock = ManualDelayClock()

    init(text: String = "let s = \"a\"\ns", incomplete: Bool = false, items: [CompletionItem] = members) {
        let session = DocumentSession(path: "/w/A.swift", backend: StringDocumentBackend(loadedText: text))
        self.session = session
        caret = (text as NSString).length
        provider.answer = { _ in .items(items, isIncomplete: incomplete) }
        var box: Rig?
        controller = CompletionController(
            session: session, provider: provider,
            environment: CompletionEnvironment(
                caret: { box.flatMap { $0.hasCaret ? $0.caret : nil } },
                text: { range in (session.text as NSString).substring(with: NSRange(location: range.location, length: range.length)) },
                setCaret: { box?.carets.append($0); box?.caret = $0 }
            ),
            presenter: presenter, clock: clock
        )
        box = self
    }

    /// Typing: the text changes and the view's caret follows.
    func type(_ text: String, origin: EditOrigin = .typing) throws {
        try session.apply(
            [DocumentEdit(range: UTF16TextRange(location: caret, length: 0), replacement: text)],
            expectedVersion: session.version, origin: origin
        )
        caret += (text as NSString).length
    }

    func backspace() throws {
        try session.apply(
            [DocumentEdit(range: UTF16TextRange(location: caret - 1, length: 1), replacement: "")],
            expectedVersion: session.version, origin: .typing
        )
        caret -= 1
    }

    func settle() async {
        for _ in 0..<40 { await Task.yield() }
    }

    /// Lets the whole time allowed for an answer pass. The second timer is only set once the first
    /// has run out, so it is two steps.
    func letTheTimeoutPass() async {
        clock.advance(by: .milliseconds(300))
        await settle()
        clock.advance(by: .milliseconds(4700))
        await settle()
    }
}

// MARK: Starting

@Test @MainActor
func aTypedDotAfterAWordStartsCompletionAtTheCaretAfterIt() async throws {
    let rig = Rig()
    try rig.type(".")
    await rig.settle()
    #expect(rig.provider.calls.map(\.caret) == [14])
    let shown = try #require(rig.presenter.shown.last)
    #expect(shown.anchor == 14 && shown.selected == 0)
    #expect(shown.labels == ["Array", "append(contentsOf: String)", "count", "hasPrefix(prefix: String)", "uppercased()"], "in the server's sort order")
}

@Test @MainActor
func aDotThatIsNotMemberAccessStartsNothing() async throws {
    for (text, typed) in [("let x = 1", "."), ("let x = ", "."), ("let r = 0.", "."), ("x ", ".")] {
        let rig = Rig(text: text)
        try rig.type(typed)
        await rig.settle()
        #expect(rig.provider.calls.isEmpty, "after \(text.debugDescription)")
    }
    for text in ["foo()", "a[0]", "x?", "y!", "closure}"] {
        let rig = Rig(text: text)
        try rig.type(".")
        await rig.settle()
        #expect(rig.provider.calls.count == 1, "after \(text.debugDescription)")
    }
    let named = Rig(text: "value1")
    try named.type(".")
    await named.settle()
    #expect(named.provider.calls.count == 1, "a name that ends in a digit is still a name")
}

@Test @MainActor
func aDotThatIsPastedOrComposedOrAProgrammaticEditStartsNothing() async throws {
    let rig = Rig(text: "x")
    try rig.type(".", origin: .command)
    try rig.backspace()
    try rig.type(".", origin: .composition)
    try rig.type("y")
    try rig.type(".", origin: .languageAction)
    await rig.settle()
    #expect(rig.provider.calls.isEmpty)
}

@Test @MainActor
func askingByHandInTheMiddleOfAWordCompletesFromTheStartOfTheWord() async throws {
    let rig = Rig(text: "s.app")
    rig.controller.requestManually()
    await rig.settle()
    #expect(rig.provider.calls.map(\.caret) == [5])
    let shown = try #require(rig.presenter.shown.last)
    #expect(shown.anchor == 2)
    #expect(shown.labels == ["append(contentsOf: String)"], "narrowed to what was typed")
}

@Test @MainActor
func askingByHandWhereThereIsNoWordCompletesAtTheCaret() async throws {
    let rig = Rig(text: "s. ")
    rig.controller.requestManually()
    await rig.settle()
    #expect(rig.presenter.shown.last?.anchor == 3)
    #expect(rig.presenter.shown.last?.labels.count == 5)
}

@Test @MainActor
func askingByHandWithTextSelectedOrMarkedDoesNothing() async throws {
    let selected = Rig(text: "abc")
    selected.hasCaret = false   // text is selected: there is no caret
    selected.controller.requestManually()
    await selected.settle()
    #expect(selected.provider.calls.isEmpty)

    let marked = Rig(text: "abc")
    marked.session.compositionDidChange(.began)
    marked.controller.requestManually()
    await marked.settle()
    #expect(marked.provider.calls.isEmpty)
    marked.session.compositionDidChange(.ended)
}

// MARK: Narrowing

@Test @MainActor
func typingTheStartOfAWordNarrowsTheListWithoutAskingAgain() async throws {
    let rig = Rig()
    try rig.type(".")
    await rig.settle()
    try rig.type("a")
    #expect(rig.presenter.shown.last?.labels == ["append(contentsOf: String)", "Array"], "exact case first, then any case")
    try rig.type("p")
    #expect(rig.presenter.shown.last?.labels == ["append(contentsOf: String)"])
    await rig.settle()
    #expect(rig.provider.calls.count == 1, "the list was complete: nothing more to ask")
}

@Test @MainActor
func aListTheServerCutShortIsAskedForAgainAsTheWordGrows() async throws {
    let rig = Rig(incomplete: true)
    try rig.type(".")
    await rig.settle()
    try rig.type("u")
    await rig.settle()
    #expect(rig.provider.calls.map(\.caret) == [14, 15])
    #expect(rig.presenter.shown.last?.labels == ["uppercased()"])
}

@Test @MainActor
func backspaceWidensTheListAndBackspacingOverTheDotEndsIt() async throws {
    let rig = Rig()
    try rig.type(".")
    await rig.settle()
    try rig.type("co")
    #expect(rig.presenter.shown.last?.labels == ["count"])
    try rig.backspace()
    #expect(rig.presenter.shown.last?.labels == ["count"], "\"c\" still matches only count; widened below")
    try rig.backspace()
    #expect(rig.presenter.shown.last?.labels.count == 5)
    #expect(rig.controller.isActive)
    try rig.backspace()   // the dot itself
    #expect(!rig.controller.isActive && !rig.presenter.isVisible)
}

@Test @MainActor
func aCharacterThatIsNotPartOfAWordEndsCompletion() async throws {
    for typed in ["(", " ", ",", "\n", ")", "="] {
        let rig = Rig()
        try rig.type(".")
        await rig.settle()
        try rig.type("a")
        try rig.type(typed)
        #expect(!rig.controller.isActive, "after \(typed.debugDescription)")
        #expect(!rig.presenter.isVisible)
    }
}

@Test @MainActor
func whenNothingMatchesTheListHidesButComesBackWhenTheWordShortens() async throws {
    let rig = Rig()
    try rig.type(".")
    await rig.settle()
    try rig.type("zz")
    #expect(!rig.presenter.isVisible && rig.controller.isActive && !rig.controller.isShowing)
    #expect(!rig.controller.accept(), "Return is a newline, not an acceptance, when no list is showing")
    try rig.backspace()
    try rig.backspace()
    #expect(rig.presenter.isVisible && rig.controller.isShowing)
}

// MARK: Ending

@Test @MainActor
func aCaretThatMovedEndsCompletionOneThatDidNotDoesNot() async throws {
    let rig = Rig()
    try rig.type(".")
    await rig.settle()
    rig.controller.selectionDidChange()
    await rig.settle()
    #expect(rig.controller.isActive, "the caret is where the word ends")

    rig.caret = 3
    rig.controller.selectionDidChange()
    await rig.settle()
    #expect(!rig.controller.isActive && !rig.presenter.isVisible)
}

@Test @MainActor
func theSelectionOfAKeystrokeReportedBeforeItsEditDoesNotEndCompletion() async throws {
    let rig = Rig()
    try rig.type(".")
    await rig.settle()
    // The view moved its caret and said so; the session's change comes in the same turn.
    rig.caret += 1
    rig.controller.selectionDidChange()
    try rig.session.apply([DocumentEdit(range: UTF16TextRange(location: rig.caret - 1, length: 0), replacement: "a")], expectedVersion: rig.session.version, origin: .typing)
    await rig.settle()
    #expect(rig.controller.isActive)
}

@Test @MainActor
func anyEditThatIsNotTypingAtTheEndOfTheWordEndsCompletion() async throws {
    let cases: [(String, (Rig) throws -> Void)] = [
        ("elsewhere", { try $0.session.apply([DocumentEdit(range: UTF16TextRange(location: 0, length: 0), replacement: "// ")], expectedVersion: $0.session.version, origin: .typing) }),
        ("a command", { try $0.type("x", origin: .command) }),
        ("an undo", { try $0.type("x", origin: .undo) }),
        ("two edits at once", { try $0.session.apply([
            DocumentEdit(range: UTF16TextRange(location: 0, length: 0), replacement: "a"),
            DocumentEdit(range: UTF16TextRange(location: 14, length: 0), replacement: "b"),
        ], expectedVersion: $0.session.version, origin: .typing) }),
    ]
    for (name, edit) in cases {
        let rig = Rig()
        try rig.type(".")
        await rig.settle()
        try edit(rig)
        #expect(!rig.controller.isActive, "\(name)")
    }
}

@Test @MainActor
func markedTextEndsCompletion() async throws {
    let rig = Rig()
    try rig.type(".")
    await rig.settle()
    rig.session.compositionDidChange(.began)
    #expect(!rig.controller.isActive && !rig.presenter.isVisible)
    rig.session.compositionDidChange(.ended)
}

@Test @MainActor
func dismissingWhileTheServerThinksDropsItsAnswer() async throws {
    let rig = Rig()
    var release: CheckedContinuation<Void, Never>?
    rig.provider.answer = { _ in
        await withCheckedContinuation { release = $0 }
        return .items(members, isIncomplete: false)
    }
    try rig.type(".")
    await rig.settle()
    rig.controller.dismiss()
    release?.resume()
    await rig.settle()
    #expect(!rig.presenter.isVisible && rig.presenter.shown.isEmpty)
}

@Test @MainActor
func theAnswerToAnEarlierRequestDoesNotReplaceTheLaterOne() async throws {
    let rig = Rig(incomplete: true)
    var gates: [CheckedContinuation<Void, Never>] = []
    rig.provider.answer = { call in
        if call == 1 { await withCheckedContinuation { gates.append($0) } }
        // Both match what is typed by then, so only the check of which request it was tells them apart.
        return .items(call == 1 ? [item("nOld")] : [item("new")], isIncomplete: true)
    }
    try rig.type(".")
    await rig.settle()
    try rig.type("n")             // asks again; the first answer is still out
    await rig.settle()
    gates.forEach { $0.resume() }
    await rig.settle()
    #expect(rig.presenter.shown.map(\.labels) == [["new"]], "the first answer was dropped")
}

@Test @MainActor
func completionOverMarkedTextEndsQuietly() async throws {
    let rig = Rig()
    rig.provider.answer = { _ in .suppressedByComposition }
    try rig.type(".")
    await rig.settle()
    #expect(!rig.controller.isActive && !rig.presenter.isVisible && rig.presenter.statuses.isEmpty)
}

// MARK: Choosing and accepting

@Test @MainActor
func theSelectionMovesAndWrapsAndFollowsAClick() async throws {
    let rig = Rig()
    try rig.type(".")
    await rig.settle()
    rig.controller.moveSelection(by: -1)
    rig.controller.moveSelection(by: 1)
    rig.controller.moveSelection(by: 1)
    rig.controller.select(row: 3)
    #expect(rig.presenter.selections == [4, 0, 1, 3])
}

@Test @MainActor
func acceptingReplacesTheTypedWordAndPutsTheCaretInsideTheParenthesesOfACallWithArguments() async throws {
    let rig = Rig()
    try rig.type(".")
    await rig.settle()
    try rig.type("app")
    let before = rig.session.version
    #expect(rig.controller.accept())
    #expect(rig.session.text == "let s = \"a\"\ns.append(contentsOf: )")
    #expect(rig.session.version == before + 1, "one edit")
    #expect(rig.carets == [(rig.session.text as NSString).length - 1], "between the parentheses")
    #expect(!rig.controller.isActive && !rig.presenter.isVisible)
}

@Test @MainActor
func acceptingACallWithNoArgumentsOrAPropertyPutsTheCaretAfterIt() async throws {
    let rig = Rig()
    try rig.type(".")
    await rig.settle()
    try rig.type("up")
    #expect(rig.controller.accept())
    #expect(rig.session.text.hasSuffix("s.uppercased()"))
    #expect(rig.carets == [(rig.session.text as NSString).length])

    let property = Rig()
    try property.type(".")
    await property.settle()
    try property.type("cou")
    #expect(property.controller.accept())
    #expect(property.session.text.hasSuffix("s.count") && property.carets == [(property.session.text as NSString).length])
}

@Test @MainActor
func acceptingTheSelectedRowNotTheFirst() async throws {
    let rig = Rig()
    try rig.type(".")
    await rig.settle()
    rig.controller.moveSelection(by: 2)    // count
    #expect(rig.controller.accept())
    #expect(rig.session.text.hasSuffix("s.count"))
}

@Test @MainActor
func acceptingAfterTheCaretMovedChangesNothing() async throws {
    let rig = Rig()
    try rig.type(".")
    await rig.settle()
    let text = rig.session.text
    rig.caret = 2
    #expect(!rig.controller.accept())
    #expect(rig.session.text == text && !rig.controller.isActive)
}

@Test @MainActor
func acceptingIsOneUndoableLanguageActionEdit() async throws {
    let rig = Rig()
    var origins: [EditOrigin] = []
    rig.session.subscribeToChanges { origins.append($0.origin) }
    try rig.type(".")
    await rig.settle()
    origins.removeAll()
    _ = rig.controller.accept()
    #expect(origins == [.languageAction])
}

// MARK: Filtering on its own

@Test @MainActor
func theFilterRanksExactCaseThenAnyCaseThenALaterWord() {
    let items = [item("hasPrefix(prefix:)", filter: "hasPrefix(:)"), item("Prefix"), item("prefix"), item("my_prefix"), item("suffix")]
    #expect(CompletionController.filter(items, prefix: "pre", limit: 10).map(\.label) == ["prefix", "Prefix", "hasPrefix(prefix:)", "my_prefix"])
    #expect(CompletionController.filter(items, prefix: "", limit: 2).count == 2, "a limit applies")
    #expect(CompletionController.filter(items, prefix: "zzz", limit: 10).isEmpty)
}

@Test @MainActor
func aMatchInTheMiddleOfAWordIsNotAMatch() {
    let items = [item("uppercased()"), item("count", kind: .property)]
    #expect(CompletionController.filter(items, prefix: "a", limit: 10).isEmpty)
    #expect(CompletionController.filter(items, prefix: "cas", limit: 10).isEmpty, "\"cas\" is inside \"uppercased\", not at a word of it")
}

@Test @MainActor
func theFilterUsesTheFilterTextNotTheLabel() {
    let items = [item("append(contentsOf: String)", filter: "append(contentsOf:)")]
    #expect(CompletionController.filter(items, prefix: "append(c", limit: 5).count == 1)
    #expect(CompletionController.filter(items, prefix: "String", limit: 5).isEmpty, "the label's type text is not matched")
}

// MARK: The range the server names

private func ranged(_ label: String, insert: String? = nil, from: Int, to: Int) -> CompletionItem {
    CompletionItem(label: label, insertText: insert ?? label, sortText: label, filterText: label,
                   replacementRange: UTF16TextRange(location: from, length: to - from), kind: .property)
}

@Test @MainActor
func aRangeThatReachesPastTheCaretReplacesTheRestOfTheWordToo() async throws {
    let rig = Rig(text: "s.count", items: [ranged("count", from: 2, to: 7)])
    rig.caret = 5               // s.cou|nt
    rig.controller.requestManually()
    await rig.settle()
    #expect(rig.controller.accept())
    #expect(rig.session.text == "s.count", "not s.countnt")
    #expect(rig.carets == [7])
}

@Test @MainActor
func theServersRangeFollowsWhatIsTypedInsideIt() async throws {
    let rig = Rig(text: "s.xx", items: [ranged("count", from: 2, to: 4)])
    rig.caret = 2
    rig.controller.requestManually()
    await rig.settle()
    try rig.type("cou")         // s.cou|xx: the range now ends after the typed text as well
    #expect(rig.controller.accept())
    #expect(rig.session.text == "s.count")
}

@Test @MainActor
func aRangeThatStartsBeforeTheWordReplacesWhatItNames() async throws {
    // s.ap|  with the item `?.append()` over `.ap`: optional chaining instead of a plain member
    let rig = Rig(text: "s.ap", items: [ranged("append", insert: "?.append()", from: 1, to: 4)])
    rig.controller.requestManually()
    await rig.settle()
    #expect(rig.controller.accept())
    #expect(rig.session.text == "s?.append()")
    #expect(rig.carets == [(rig.session.text as NSString).length])
}

@Test @MainActor
func anItemWhoseRangeDoesNotContainTheCaretIsNotOffered() async throws {
    let rig = Rig(text: "s.", items: [ranged("count", from: 0, to: 1), ranged("isEmpty", from: 2, to: 2), item("first")])
    rig.caret = 2
    rig.controller.requestManually()
    await rig.settle()
    #expect(rig.presenter.shown.last?.labels == ["first", "isEmpty"], "count names text elsewhere, so it is left out")
}

@Test @MainActor
func anItemIsDroppedWhenTheCaretLeavesItsRangeBackwards() async throws {
    let rig = Rig(text: "s.ap", items: [ranged("append", from: 3, to: 4), item("applying")])
    rig.controller.requestManually()
    await rig.settle()
    #expect(rig.presenter.shown.last?.labels.contains("append") == true)
    try rig.backspace()         // s.a|: the caret is at the start of the range, still in it
    #expect(rig.presenter.shown.last?.labels.contains("append") == true)
    try rig.backspace()         // s.|: before the range start (3)
    #expect(rig.presenter.shown.last?.labels == ["applying"])
}

// MARK: Saying why there is no list

@MainActor
private func hold(_ rig: Rig) -> Box<CheckedContinuation<CompletionOutcome, Never>> {
    let held = Box<CheckedContinuation<CompletionOutcome, Never>>()
    rig.provider.answer = { _ in
        await withCheckedContinuation { held.value = $0 }
    }
    return held
}

@MainActor
private final class Box<T> { var value: T? }

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false
    func raise() { lock.withLock { raised = true } }
    var isRaised: Bool { lock.withLock { raised } }
}

@Test @MainActor
func aSlowAnswerIsAnnouncedAfterTheNoticeDelayAndNotBefore() async throws {
    let rig = Rig()
    let held = hold(rig)
    try rig.type(".")
    await rig.settle()
    rig.clock.advance(by: .milliseconds(299))
    await rig.settle()
    #expect(rig.presenter.statuses.isEmpty, "a quick answer flashes nothing")
    rig.clock.advance(by: .milliseconds(1))
    await rig.settle()
    #expect(rig.presenter.statuses == [.waiting] && rig.controller.isActive)
    held.value?.resume(returning: .items(members, isIncomplete: false))
    await rig.settle()
    #expect(rig.presenter.shown.last?.labels.count == 5, "the list replaces the notice")
}

@Test @MainActor
func theNoticeIsNotShownOverAListThatIsAlreadyThere() async throws {
    let rig = Rig(incomplete: true)
    try rig.type(".")
    await rig.settle()
    rig.provider.answer = { _ in await withCheckedContinuation { _ in } }
    try rig.type("a")           // the list was cut short: asked again, and the answer is slow
    await rig.settle()
    rig.clock.advance(by: .milliseconds(300))
    await rig.settle()
    #expect(rig.presenter.statuses.isEmpty && rig.presenter.isVisible)
}

@Test @MainActor
func anAnswerThatNeverComesIsWithdrawnAndTheUserToldAtTheTimeout() async throws {
    let rig = Rig()
    let cancelled = Flag()
    rig.provider.answer = { _ in
        await withTaskCancellationHandler {
            await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
        } onCancel: { cancelled.raise() }
        return .items(members, isIncomplete: false)
    }
    try rig.type(".")
    await rig.settle()
    rig.clock.advance(by: .milliseconds(300))
    await rig.settle()
    rig.clock.advance(by: .milliseconds(4699))
    await rig.settle()
    #expect(rig.presenter.statuses == [.waiting], "not yet")
    rig.clock.advance(by: .milliseconds(1))
    await rig.settle()
    #expect(rig.presenter.statuses == [.waiting, .notResponding])
    #expect(cancelled.isRaised, "the question is withdrawn from the server")
    #expect(!rig.controller.isActive)
}

@Test @MainActor
func anAnswerThatArrivesAfterTheTimeoutChangesNothing() async throws {
    let rig = Rig()
    let held = hold(rig)
    try rig.type(".")
    await rig.settle()
    await rig.letTheTimeoutPass()
    #expect(rig.presenter.statuses.last == .notResponding)
    held.value?.resume(returning: .items(members, isIncomplete: false))
    await rig.settle()
    #expect(rig.presenter.shown.isEmpty && !rig.controller.isActive)
}

@Test @MainActor
func anAnswerInTimeStopsTheClocks() async throws {
    let rig = Rig()
    try rig.type(".")
    await rig.settle()
    #expect(rig.clock.sleeperCount == 0, "no timer is left running after the answer")
    rig.clock.advance(by: .seconds(10))
    await rig.settle()
    #expect(rig.presenter.statuses.isEmpty && rig.controller.isShowing)
}

@Test @MainActor
func aListThatIsOnScreenSurvivesTheTimeoutOfTheNextQuestion() async throws {
    let rig = Rig(incomplete: true)
    try rig.type(".")
    await rig.settle()
    let cancelled = Flag()
    let held = Box<CheckedContinuation<Void, Never>>()
    rig.provider.answer = { _ in
        await withTaskCancellationHandler {
            await withCheckedContinuation { held.value = $0 }
        } onCancel: { cancelled.raise() }
        return .items([item("appeared")], isIncomplete: true)
    }
    try rig.type("a")
    await rig.settle()
    let shownBefore = rig.presenter.shown.count
    await rig.letTheTimeoutPass()
    #expect(rig.presenter.statuses.isEmpty && rig.controller.isShowing, "the cut-short list stays usable")
    #expect(cancelled.isRaised, "the question is withdrawn all the same")
    held.value?.resume()
    await rig.settle()
    #expect(rig.presenter.shown.count == shownBefore, "an answer that comes after the timeout is not shown")
    try rig.type("p")
    await rig.settle()
    #expect(rig.provider.calls.count == 2, "and the list is not asked again and again")
}

@Test @MainActor
func eachReasonTheServerCannotBeUsedHasItsOwnStatusWhenAskedByHand() async throws {
    let cases: [(LanguageServiceUnavailable, CompletionStatus)] = [
        (.starting, .starting), (.restarting, .restarting), (.documentNotSynced, .notReady),
        (.failed("boom"), .unavailable), (.notRunning, .unavailable),
    ]
    for (reason, status) in cases {
        let rig = Rig(text: "s.")
        rig.provider.answer = { _ in .unavailable(reason) }
        rig.controller.requestManually()
        await rig.settle()
        #expect(rig.presenter.statuses == [status], "\(reason)")
        #expect(!rig.controller.isActive)
    }
}

@Test @MainActor
func afterADotAServerThatIsStartingIsReportedButADocumentWithNoServerIsLeftAlone() async throws {
    for (reason, shown) in [(LanguageServiceUnavailable.starting, true), (.failed("x"), true), (.notRunning, false)] {
        let rig = Rig()
        rig.provider.answer = { _ in .unavailable(reason) }
        try rig.type(".")
        await rig.settle()
        #expect(rig.presenter.statuses.isEmpty == !shown, "\(reason)")
    }
}

@Test @MainActor
func noSuggestionsIsSaidWhenAskedByHandAndNotAfterADot() async throws {
    let manual = Rig(text: "s.")
    manual.provider.answer = { _ in .items([], isIncomplete: false) }
    manual.controller.requestManually()
    await manual.settle()
    #expect(manual.presenter.statuses == [.noSuggestions] && !manual.controller.isActive)

    let filtered = Rig(text: "s.zzz")
    filtered.controller.requestManually()    // there are suggestions, none starts with what was typed
    await filtered.settle()
    #expect(filtered.presenter.statuses == [.noSuggestions])

    let afterDot = Rig()
    afterDot.provider.answer = { _ in .items([], isIncomplete: false) }
    try afterDot.type(".")
    await afterDot.settle()
    #expect(afterDot.presenter.statuses.isEmpty && !afterDot.controller.isActive, "nothing on screen, nothing left open")
}

@Test @MainActor
func aStatusGoesAwayByItselfAndAtTheNextKey() async throws {
    let rig = Rig(text: "s.")
    rig.provider.answer = { _ in .unavailable(.failed("x")) }
    rig.controller.requestManually()
    await rig.settle()
    #expect(rig.presenter.isVisible)
    rig.clock.advance(by: .milliseconds(1999))
    await rig.settle()
    #expect(rig.presenter.isVisible)
    rig.clock.advance(by: .milliseconds(1))
    await rig.settle()
    #expect(!rig.presenter.isVisible, "taken down after two seconds")

    rig.controller.requestManually()
    await rig.settle()
    #expect(rig.presenter.isVisible)
    try rig.type("a")
    #expect(!rig.presenter.isVisible, "and by the next thing typed")
    rig.controller.requestManually()
    await rig.settle()
    rig.controller.selectionDidChange()
    #expect(!rig.presenter.isVisible, "or a click")
}

// MARK: A server that is not ready says "nothing yet, more to come"

@Test @MainActor
func anEmptyCutShortAnswerIsAskedAgainShortlyUntilThereIsAList() async throws {
    let rig = Rig()
    rig.provider.answer = { call in call < 3 ? .items([], isIncomplete: true) : .items(members, isIncomplete: false) }
    try rig.type(".")
    await rig.settle()
    #expect(rig.provider.calls.count == 1 && rig.presenter.shown.isEmpty && rig.controller.isActive)
    #expect(rig.presenter.statuses == [.waiting], "the user is told the server is busy, not left with nothing")
    rig.clock.advance(by: .milliseconds(499))
    await rig.settle()
    #expect(rig.provider.calls.count == 1, "not before the pause is over")
    rig.clock.advance(by: .milliseconds(1))
    await rig.settle()
    #expect(rig.provider.calls.count == 2)
    rig.clock.advance(by: .milliseconds(500))
    await rig.settle()
    #expect(rig.provider.calls.count == 3 && rig.controller.isShowing, "the third answer is the list")
}

@Test @MainActor
func aServerThatStaysBusyIsAskedManyTimesThenTheUserIsToldItIsNotReady() async throws {
    for manual in [true, false] {
        let rig = Rig(text: manual ? "s." : "let s = \"a\"\ns")
        rig.provider.answer = { _ in .items([], isIncomplete: true) }
        if manual { rig.controller.requestManually() } else { try rig.type(".") }
        await rig.settle()
        for _ in 0..<30 {
            rig.clock.advance(by: .milliseconds(500))
            await rig.settle()
        }
        #expect(rig.provider.calls.count == 21, "the first question and twenty more")
        #expect(rig.presenter.statuses.last == .notReady && !rig.controller.isActive, "manual: \(manual)")
    }
}

@Test @MainActor
func typingDuringThePauseAsksAtOnceAndTheWaitingPauseIsForgotten() async throws {
    let rig = Rig()
    rig.provider.answer = { call in call == 1 ? .items([], isIncomplete: true) : .items(members, isIncomplete: false) }
    try rig.type(".")
    await rig.settle()
    try rig.type("a")           // asks now
    await rig.settle()
    #expect(rig.provider.calls.count == 2 && rig.controller.isShowing)
    rig.clock.advance(by: .seconds(1))
    await rig.settle()
    #expect(rig.provider.calls.count == 2, "the old pause does not ask a third time")
}

@Test @MainActor
func dismissingDuringThePauseStopsTheRetry() async throws {
    let rig = Rig()
    rig.provider.answer = { _ in .items([], isIncomplete: true) }
    try rig.type(".")
    await rig.settle()
    rig.controller.dismiss()
    rig.clock.advance(by: .seconds(1))
    await rig.settle()
    #expect(rig.provider.calls.count == 1)
}
