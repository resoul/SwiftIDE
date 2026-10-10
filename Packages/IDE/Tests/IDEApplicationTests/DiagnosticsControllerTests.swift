import Foundation
import IDEApplication
import IDEDomain
import IDETestSupport
import Testing

@MainActor
private final class FakeProvider: DiagnosticsProviding {
    var report: DocumentDiagnostics?
    private var observers: [UUID: @MainActor () -> Void] = [:]

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

    var observerCount: Int { observers.count }
}

@MainActor
private final class FakePresenter: DiagnosticsPresenting {
    private(set) var shown: [[DiagnosticMark]] = []
    func show(_ marks: [DiagnosticMark]) { shown.append(marks) }
    var last: [DiagnosticMark] { shown.last ?? [] }
}

private func diagnostic(_ location: Int, _ length: Int, _ severity: DocumentDiagnostic.Severity = .error, _ message: String = "boom") -> DocumentDiagnostic {
    DocumentDiagnostic(range: UTF16TextRange(location: location, length: length), severity: severity, message: message)
}

@MainActor
private struct Rig {
    let session = DocumentSession(path: "/w/A.swift", backend: StringDocumentBackend(loadedText: "let a = 1\nlet b = 2\nlet c = 3\n"))
    let provider = FakeProvider()
    let presenter = FakePresenter()
    let controller: DiagnosticsController

    init() {
        controller = DiagnosticsController(session: session, provider: provider, presenter: presenter)
    }

    func report(_ items: [DocumentDiagnostic], verified: Bool = false) {
        provider.publish(DocumentDiagnostics(items: items, version: session.version, isVerified: verified))
    }

    func edit(_ location: Int, _ length: Int, _ text: String) throws {
        try session.apply([DocumentEdit(range: UTF16TextRange(location: location, length: length), replacement: text)], expectedVersion: session.version, origin: .typing)
    }
}

// MARK: Showing a report

@Test @MainActor
func aReportBecomesMarksAndASummary() {
    let rig = Rig()
    #expect(rig.controller.marks.isEmpty && rig.controller.summary.text == nil)
    rig.report([diagnostic(4, 1), diagnostic(14, 1, .warning), diagnostic(24, 1, .warning), diagnostic(0, 3, .hint)])

    #expect(rig.controller.marks.count == 4 && rig.presenter.last == rig.controller.marks)
    #expect(rig.controller.marks.allSatisfy { !$0.isStale })
    #expect(rig.controller.summary == DiagnosticsController.Summary(errors: 1, warnings: 2))
    #expect(rig.controller.summary.text == "1 error, 2 warnings")
}

@Test
func theSummaryUsesTheSingularAndLeavesOutWhatIsZero() {
    #expect(DiagnosticsController.Summary(errors: 2, warnings: 0).text == "2 errors")
    #expect(DiagnosticsController.Summary(errors: 0, warnings: 1).text == "1 warning")
    #expect(DiagnosticsController.Summary(errors: 1, warnings: 1).text == "1 error, 1 warning")
    #expect(DiagnosticsController.Summary().text == nil)
}

@Test @MainActor
func noReportOrAReportTheDocumentHasMovedPastLeavesNothing() throws {
    let rig = Rig()
    rig.report([diagnostic(4, 1)])
    rig.provider.publish(nil)
    #expect(rig.controller.marks.isEmpty && rig.presenter.last.isEmpty)

    let old = DocumentDiagnostics(items: [diagnostic(4, 1)], version: rig.session.version, isVerified: true)
    try rig.edit(0, 0, "x")
    rig.provider.publish(old)
    #expect(rig.controller.marks.isEmpty, "a report for version 0 cannot be placed in the text of version 1")
}

// MARK: Following the text

@Test @MainActor
func marksMoveWithTheTextAndAreStaleUntilTheNextReport() throws {
    let rig = Rig()
    rig.report([diagnostic(14, 1)])           // the "b" of line 2
    try rig.edit(0, 0, "// note\n")           // eight characters in front
    let mark = try #require(rig.controller.marks.first)
    #expect(mark.range == UTF16TextRange(location: 22, length: 1) && mark.isStale)

    try rig.edit(0, 5, "")                    // five taken off again
    #expect(rig.controller.marks.first?.range == UTF16TextRange(location: 17, length: 1))

    rig.report([diagnostic(17, 1)])
    #expect(rig.controller.marks.first?.isStale == false, "the new report is fresh")
}

@Test @MainActor
func editsAfterAMarkLeaveItAlone() throws {
    let rig = Rig()
    rig.report([diagnostic(4, 1)])
    try rig.edit(20, 0, "zzz")
    #expect(rig.controller.marks.first?.range == UTF16TextRange(location: 4, length: 1))
}

@Test @MainActor
func textTypedInsideAMarkGrowsItAndTextAtItsEdgesDoesNot() throws {
    let rig = Rig()
    rig.report([diagnostic(4, 3)])            // "a =" of line 1
    try rig.edit(5, 0, "XY")                  // inside
    #expect(rig.controller.marks.first?.range == UTF16TextRange(location: 4, length: 5))

    try rig.edit(9, 0, "!")                   // at its end: not part of it
    #expect(rig.controller.marks.first?.range == UTF16TextRange(location: 4, length: 5))

    try rig.edit(4, 0, "?")                   // at its start: it moves on
    #expect(rig.controller.marks.first?.range == UTF16TextRange(location: 5, length: 5))
}

@Test @MainActor
func deletingTextCoveringAMarkShrinksItToNothingButItStays() throws {
    let rig = Rig()
    rig.report([diagnostic(4, 3)])
    try rig.edit(2, 8, "")                    // takes the whole mark and more
    let mark = try #require(rig.controller.marks.first)
    #expect(mark.range == UTF16TextRange(location: 2, length: 0) && mark.isStale)
}

@Test @MainActor
func aReplacementOverTheMiddleKeepsTheEndsOutsideIt() throws {
    let rig = Rig()
    rig.report([diagnostic(4, 5)])            // 4..<9
    try rig.edit(6, 2, "ABCDE")               // replaces 6..<8 by five characters
    #expect(rig.controller.marks.first?.range == UTF16TextRange(location: 4, length: 8))
}

@Test @MainActor
func aChangeThatDoesNotFollowOnTakesTheMarksOff() throws {
    let rig = Rig()
    rig.report([diagnostic(4, 1)])
    try rig.edit(0, 0, "a")
    #expect(rig.controller.marks.count == 1)
    // A report delivered for a version that is not the one the controller is following.
    rig.provider.report = DocumentDiagnostics(items: [diagnostic(4, 1)], version: rig.session.version, isVerified: true)
    try rig.edit(0, 0, "b")
    #expect(rig.controller.marks.count == 1, "followed again: the version was the controller's")
}

// MARK: Questions

@Test @MainActor
func marksAtAPlaceAreWorstFirstAndAnEmptyMarkCoversItsOwnCharacter() {
    let rig = Rig()
    rig.report([diagnostic(4, 3, .warning, "careful"), diagnostic(5, 1, .error, "broken"), diagnostic(10, 0, .information, "look")])
    #expect(rig.controller.marks(at: 5).map(\.message) == ["broken", "careful"])
    #expect(rig.controller.marks(at: 4).map(\.message) == ["careful"])
    #expect(rig.controller.marks(at: 7).isEmpty)
    #expect(rig.controller.marks(at: 10).map(\.message) == ["look"])
}

@Test @MainActor
func theMarginGetsTheWorstSeverityOfEachLine() {
    let rig = Rig()
    rig.report([diagnostic(4, 1, .warning), diagnostic(6, 1, .error), diagnostic(24, 1, .hint)])
    let lines = rig.controller.severitiesByLine { $0 / 10 }
    #expect(lines == [0: .error, 2: .hint])
}

@Test @MainActor
func letGoOfTheControllerStopsListening() {
    let provider = FakeProvider()
    let session = DocumentSession(path: "/w/A.swift", backend: StringDocumentBackend(loadedText: "x"))
    var controller: DiagnosticsController? = DiagnosticsController(session: session, provider: provider, presenter: FakePresenter())
    #expect(provider.observerCount == 1 && controller != nil)
    controller = nil
    #expect(provider.observerCount == 0)
}

// MARK: Placement on its own

@Test
func placementThroughSeveralEditsOfOneChangeSet() {
    // Descending, in the coordinates of the text before: replace 20..<22, then insert at 10, then delete 0..<3.
    let edits = [
        DocumentEdit(range: UTF16TextRange(location: 20, length: 2), replacement: "ABCD"),
        DocumentEdit(range: UTF16TextRange(location: 10, length: 0), replacement: "++"),
        DocumentEdit(range: UTF16TextRange(location: 0, length: 3), replacement: ""),
    ]
    #expect(DiagnosticPlacement.range(UTF16TextRange(location: 12, length: 4), through: edits) == UTF16TextRange(location: 11, length: 4), "-3 before, +2 insertion before")
    #expect(DiagnosticPlacement.range(UTF16TextRange(location: 24, length: 2), through: edits) == UTF16TextRange(location: 25, length: 2), "-3 +2 +2 before")
    #expect(DiagnosticPlacement.range(UTF16TextRange(location: 4, length: 4), through: edits) == UTF16TextRange(location: 1, length: 4))
}

@Test
func aReplacementThatEndsWhereAMarkStartsMovesTheMarkAndOneThatEndsWhereItEndsTakesItsEndAlong() {
    let mark = UTF16TextRange(location: 4, length: 5)       // 4..<9
    #expect(DiagnosticPlacement.range(mark, through: [DocumentEdit(range: UTF16TextRange(location: 2, length: 2), replacement: "ABCDE")]) == UTF16TextRange(location: 7, length: 5))
    #expect(DiagnosticPlacement.range(mark, through: [DocumentEdit(range: UTF16TextRange(location: 7, length: 2), replacement: "XYZ")]) == UTF16TextRange(location: 4, length: 6))
    #expect(DiagnosticPlacement.range(mark, through: [DocumentEdit(range: UTF16TextRange(location: 9, length: 2), replacement: "X")]) == mark, "starting where the mark ends: not part of it")
}

@Test @MainActor
func aLineWithAWarningAndLaterAnErrorShowsTheErrorWhateverTheOrder() {
    let rig = Rig()
    rig.report([diagnostic(6, 1, .error), diagnostic(4, 1, .warning)])
    #expect(rig.controller.severitiesByLine { $0 / 10 } == [0: .error])
}

// MARK: How far a place can be trusted

@Test @MainActor
func aReportThatNamesItsVersionIsVerifiedOneThatDoesNotIsNot() {
    let rig = Rig()
    rig.report([diagnostic(4, 1)], verified: true)
    #expect(rig.controller.marks.map(\.freshness) == [.verified])
    rig.report([diagnostic(4, 1)], verified: false)
    #expect(rig.controller.marks.map(\.freshness) == [.unverified], "the lack of a version is not lost on the way to the screen")
}

@Test @MainActor
func aLateReportWithoutAVersionAfterAnEditIsShownAsUnverifiedNotAsCertain() throws {
    let rig = Rig()
    try rig.edit(0, 0, "// typed while the server was still working\n")
    // It arrives now, after the edit; the server may have analysed the text from before it.
    rig.report([diagnostic(50, 1)], verified: false)
    #expect(rig.controller.marks.map(\.freshness) == [.unverified])
    #expect(rig.controller.marks.first?.isStale == false, "no edit since it arrived")

    try rig.edit(0, 0, "x")
    #expect(rig.controller.marks.map(\.freshness) == [.stale], "any edit after it makes the place an approximation")
}

@Test @MainActor
func aVerifiedReportBecomesStaleAfterAnEditToo() throws {
    let rig = Rig()
    rig.report([diagnostic(4, 1)], verified: true)
    try rig.edit(0, 0, "x")
    #expect(rig.controller.marks.map(\.freshness) == [.stale])
    rig.report([diagnostic(5, 1)], verified: true)
    #expect(rig.controller.marks.map(\.freshness) == [.verified], "and a new report makes it sure again")
}
