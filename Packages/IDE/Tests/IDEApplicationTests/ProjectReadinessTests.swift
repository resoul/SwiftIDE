import Foundation
@testable import IDEApplication
import Testing

private func begin(_ tracker: inout ProgressTracker, _ token: String, _ title: String, message: String? = nil, percentage: Int? = nil) {
    tracker.apply(token: token, .begin(title: title, message: message, percentage: percentage))
}

// MARK: Progress

@Test
func severalOperationsAreTrackedAtOnceAndEachEndsByItself() {
    var tracker = ProgressTracker()
    begin(&tracker, "indexing.A", "Indexing")
    begin(&tracker, "package-reloading.B", "SourceKit-LSP: Reloading Package")
    #expect(tracker.operations.map(\.token) == ["indexing.A", "package-reloading.B"], "in order of arrival")

    tracker.apply(token: "package-reloading.B", .end)
    #expect(tracker.operations.map(\.token) == ["indexing.A"])
    tracker.apply(token: "indexing.A", .end)
    #expect(tracker.operations.isEmpty)
}

@Test
func aReportChangesTheOperationItBelongsToAndNoOther() {
    var tracker = ProgressTracker()
    begin(&tracker, "indexing.A", "Indexing", message: "0 / 3")
    begin(&tracker, "indexing.B", "Indexing", message: "0 / 9")
    tracker.apply(token: "indexing.B", .report(message: "4 / 9", percentage: nil))

    #expect(tracker.operations[0].counts == ProgressCounts(done: 0, total: 3))
    #expect(tracker.operations[1].counts == ProgressCounts(done: 4, total: 9))
}

@Test
func aReportOrAnEndForAnOperationThatNeverBeganIsIgnored() {
    var tracker = ProgressTracker()
    tracker.apply(token: "indexing.X", .report(message: "1 / 2", percentage: 50))
    tracker.apply(token: "indexing.X", .end)
    #expect(tracker.operations.isEmpty && !tracker.hasCompletedInitialPreparation, "an end nobody began does not count as a finished preparation")
}

@Test
func countsAreShownOnlyWhenTheServerSentThemAsNOfM() {
    var tracker = ProgressTracker()
    begin(&tracker, "indexing.A", "Indexing", message: "Determining files")
    #expect(tracker.operations[0].counts == nil, "a message that is not n / m gives no numbers")
    tracker.apply(token: "indexing.A", .report(message: "2 / 5", percentage: nil))
    #expect(tracker.operations[0].counts == ProgressCounts(done: 2, total: 5))
    tracker.apply(token: "indexing.A", .report(message: "Preparing current file", percentage: nil))
    #expect(tracker.operations[0].counts == nil, "the newest message decides: no stale numbers")
    #expect(tracker.operations[0].message == "Preparing current file")
}

@Test
func aPercentageIsKeptButNeverInventedFromTheMessage() {
    var tracker = ProgressTracker()
    begin(&tracker, "other.A", "Working", percentage: 40)
    #expect(tracker.operations[0].percentage == 40)
    tracker.apply(token: "other.A", .report(message: nil, percentage: nil))
    #expect(tracker.operations[0].percentage == 40, "a report that names none leaves it")
}

@Test
func resettingForgetsEveryOperationAndTheFinishedPreparation() {
    var tracker = ProgressTracker()
    begin(&tracker, "indexing.A", "Indexing")
    tracker.apply(token: "indexing.A", .end)
    #expect(tracker.hasCompletedInitialPreparation)
    begin(&tracker, "indexing.B", "Indexing")
    tracker.reset()

    #expect(tracker.operations.isEmpty && !tracker.hasCompletedInitialPreparation, "a restarted server prepares afresh")
}

@Test
func theInitialPreparationIsOverWhenTheFirstPreparationHasEndedAndNotBefore() {
    var tracker = ProgressTracker()
    #expect(!tracker.isInitialPreparation, "nothing seen yet proves nothing")
    begin(&tracker, "indexing.A", "Indexing")
    #expect(tracker.isInitialPreparation)
    begin(&tracker, "package-reloading.B", "Reloading")
    tracker.apply(token: "package-reloading.B", .end)
    #expect(tracker.isInitialPreparation, "indexing is still going")
    tracker.apply(token: "indexing.A", .end)
    #expect(!tracker.isInitialPreparation && tracker.hasCompletedInitialPreparation)

    begin(&tracker, "indexing.C", "Indexing")
    #expect(!tracker.isInitialPreparation, "a later indexing is not the initial one")
}

@Test
func anOperationOfAnotherKindIsNotAPreparation() {
    var tracker = ProgressTracker()
    begin(&tracker, "something.A", "Something else")
    #expect(!tracker.isInitialPreparation)
    tracker.apply(token: "something.A", .end)
    #expect(!tracker.hasCompletedInitialPreparation)
}

// MARK: Readiness

private func readiness(
    server: ServerStatus = .running,
    fallback: Bool = false,
    tracker: ProgressTracker = ProgressTracker(),
    trust: ConfigurationTrust = .undecided,
    pendingQuestion: Bool = false
) -> ProjectReadiness {
    ProjectReadiness.make(server: server, isFallbackRoot: fallback, progress: tracker, trust: trust, isAskingForTrust: pendingQuestion)
}

@Test
func withNoSignalReadinessIsUnknownAndNothingIsSaidAboutIt() {
    let r = readiness()
    #expect(r.settings == .unknown && r.reason == nil && r.diagnosticsBasis == .unconfirmed)
}

@Test
func thePackageBeingReloadedMeansTheSettingsAreLoading() {
    var tracker = ProgressTracker()
    begin(&tracker, "package-reloading.A", "SourceKit-LSP: Reloading Package")
    let r = readiness(tracker: tracker)
    #expect(r.settings == .loading && r.reason == "Reloading package")
}

@Test
func indexingAloneDoesNotMeanTheSettingsAreMissing() {
    var tracker = ProgressTracker()
    begin(&tracker, "indexing.A", "Indexing", message: "2 / 5")
    let r = readiness(tracker: tracker)
    #expect(r.settings == .unknown, "the server can work while the package is indexed")
    #expect(r.reason == "Preparing package · 2 / 5")
}

@Test
func withoutCountsThePreparationHasNoNumbersAndNoPercentage() {
    var tracker = ProgressTracker()
    begin(&tracker, "indexing.A", "Indexing", message: "Determining files")
    #expect(readiness(tracker: tracker).reason == "Preparing package")
}

@Test
func ofSeveralOperationsTheOneWithCountsIsShown() {
    var tracker = ProgressTracker()
    begin(&tracker, "package-reloading.A", "Reloading")
    begin(&tracker, "indexing.B", "Indexing", message: "1 / 4")
    #expect(readiness(tracker: tracker).reason == "Preparing package · 1 / 4")
}

@Test
func anUnknownKindOfOperationIsShownByItsOwnTitle() {
    var tracker = ProgressTracker()
    begin(&tracker, "build.A", "Compiling", message: "3 / 8")
    #expect(readiness(tracker: tracker).reason == "Compiling · 3 / 8")
}

@Test
func aServerThatIsNotRunningIsTheMostUsefulThingToSay() {
    var tracker = ProgressTracker()
    begin(&tracker, "indexing.A", "Indexing")
    #expect(readiness(server: .failed, tracker: tracker).reason == "Language server failed")
    #expect(readiness(server: .restarting, tracker: tracker).reason == "Language server restarting")
    #expect(readiness(server: .starting, tracker: tracker).reason == "Language server starting")
    #expect(readiness(server: .stopped).reason == nil)
}

@Test
func fallbackSettingsAreSaidWhenTheRootIsKnownToHaveNoProject() {
    let r = readiness(fallback: true)
    #expect(r.settings == .fallback && r.reason == "Using fallback settings" && r.diagnosticsBasis == .fallback)
}

@Test
func aRefusedConfigurationIsSaidAfterTheWorkInProgressAndBeforeFallback() {
    #expect(readiness(trust: .refused).reason == "Project configuration disabled")
    #expect(readiness(fallback: true, trust: .refused).reason == "Project configuration disabled")
    var tracker = ProgressTracker()
    begin(&tracker, "indexing.A", "Indexing")
    #expect(readiness(tracker: tracker, trust: .refused).reason == "Preparing package")
}

@Test
func whileTheUserIsAskedTheDecisionIsAwaitedNotAssumed() {
    let r = readiness(tracker: ProgressTracker(), trust: .undecided, pendingQuestion: true)
    #expect(r.reason == "Waiting for your decision on the project configuration")
}

@Test
func reportsThatArriveDuringTheInitialPreparationAreMarkedAsSuch() {
    var tracker = ProgressTracker()
    begin(&tracker, "indexing.A", "Indexing")
    #expect(readiness(tracker: tracker).diagnosticsBasis == .preparing)
    tracker.apply(token: "indexing.A", .end)
    #expect(readiness(tracker: tracker).diagnosticsBasis == .unconfirmed, "finishing does not confirm anything")
}

@Test
func fallbackOutranksPreparingForTheBasisOfADiagnostic() {
    var tracker = ProgressTracker()
    begin(&tracker, "indexing.A", "Indexing")
    #expect(readiness(fallback: true, tracker: tracker).diagnosticsBasis == .fallback)
}

@Test
func aPreparedSettingsStateIsConfirmedOnlyByAnExplicitSignal() {
    var r = readiness()
    r.settings = .prepared
    #expect(r.diagnosticsBasis == .confirmed)
}

// MARK: Trust

@MainActor
@Test
func aTrustDecisionIsKeptPerCanonicalRootAndCanBeForgotten() {
    let store = MemoryProjectTrustStore()
    #expect(store.decision(forRoot: "/w/a") == nil)
    store.record(.granted, forRoot: "/w/a")
    store.record(.refused, forRoot: "/w/b")
    #expect(store.decision(forRoot: "/w/a") == .granted && store.decision(forRoot: "/w/b") == .refused)
    store.forget(root: "/w/a")
    #expect(store.decision(forRoot: "/w/a") == nil && store.decision(forRoot: "/w/b") == .refused)
}
