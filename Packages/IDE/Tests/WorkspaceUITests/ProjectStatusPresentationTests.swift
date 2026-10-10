import IDEApplication
import Testing
import WorkspaceUI

private func begin(_ tracker: inout ProgressTracker, _ token: String, _ title: String, message: String? = nil) {
    tracker.apply(token: token, .begin(title: title, message: message, percentage: nil))
}

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
func thePriorityIsServerThenQuestionThenWorkThenRefusalThenFallback() {
    var tracker = ProgressTracker()
    begin(&tracker, "indexing.A", "Indexing", message: "2 / 5")
    #expect(readiness(server: .failed, fallback: true, tracker: tracker, trust: .refused, pendingQuestion: true).reason == "Language server failed")
    #expect(readiness(fallback: true, tracker: tracker, trust: .refused, pendingQuestion: true).reason == "Waiting for your decision on the project configuration")
    #expect(readiness(fallback: true, tracker: tracker, trust: .refused).reason == "Preparing package · 2 / 5")
    #expect(readiness(fallback: true, trust: .refused).reason == "Project configuration disabled")
    #expect(readiness(fallback: true, trust: .granted).reason == "Using fallback settings")
}

@Test
func endingOneOfTwoOperationsDoesNotHideTheOtherAndResetRemovesTheOldCounts() {
    var tracker = ProgressTracker()
    begin(&tracker, "indexing.A", "Indexing", message: "2 / 5")
    begin(&tracker, "package-reloading.B", "Reloading")
    tracker.apply(token: "indexing.A", .end)
    #expect(readiness(tracker: tracker).reason == "Reloading package")
    tracker.reset()
    #expect(readiness(server: .restarting, tracker: tracker).reason == "Language server restarting")
    #expect(readiness(tracker: tracker).reason == nil)
}

@Test
func theSubtitleNamesTheTargetAndSaysWhenItIsAmbiguous() {
    #expect(TargetNote.text(names: []) == nil, "nothing is said while it is unknown")
    #expect(TargetNote.text(names: ["App"], basis: .listed) == "Target: App")
    #expect(TargetNote.text(names: ["A", "B"], basis: .inferred) == "Target: ambiguous (A, B)")
}

@Test
func aTargetGuessedFromTheFilesPlaceIsSaidToBeInferred() {
    #expect(TargetNote.text(names: ["App"], basis: .inferred) == "Target: App (inferred)")
    #expect(TargetNote.text(names: ["App"], basis: .listed) == "Target: App", "a listed file is a fact and carries no qualifier")
}

@Test
func theNoteIsForTheCFamilyOnlyBecauseThatIsWhatLosesItsFlags() {
    #expect(TemporaryFolder.note(path: "/tmp/p/a.c", isCFamily: true) == "temporary folder: C-family flags may be missing")
    #expect(TemporaryFolder.note(path: "/tmp/p/a.swift", isCFamily: false) == nil)
    #expect(TemporaryFolder.note(path: "/Users/me/p/a.c", isCFamily: true) == nil)
}
