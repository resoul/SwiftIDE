import IDEApplication
import IDEDomain
import IDETestSupport
import Testing

@MainActor
private func dirtySession(_ name: String = "Main.swift") throws -> DocumentSession {
    let session = DocumentSession(path: name, backend: StringDocumentBackend(loadedText: "old"))
    try session.replaceText("edited", expectedVersion: 0)
    return session
}

@MainActor
private final class Script {
    var decision: UnsavedChangesDecision
    var saveResult = true
    private(set) var prompted: [String] = []
    private(set) var saved: [String] = []

    init(_ decision: UnsavedChangesDecision) { self.decision = decision }

    func coordinator() -> UnsavedChangesCoordinator {
        UnsavedChangesCoordinator(
            prompt: { [self] session in
                prompted.append(session.path)
                return decision
            },
            save: { [self] session in
                saved.append(session.path)
                return saveResult
            }
        )
    }
}

@Test @MainActor
func cleanDocumentClosesWithoutAskingAnything() async {
    let script = Script(.cancel)
    let clean = DocumentSession(path: "Clean.swift", backend: StringDocumentBackend(loadedText: "x"))
    #expect(await script.coordinator().canClose(clean))
    #expect(script.prompted.isEmpty)
}

@Test @MainActor
func discardClosesWithoutSavingAndCancelKeepsTheDocument() async throws {
    let discard = Script(.discard)
    #expect(await discard.coordinator().canClose(try dirtySession()))
    #expect(discard.saved.isEmpty)

    let cancel = Script(.cancel)
    #expect(!(await cancel.coordinator().canClose(try dirtySession())))
    #expect(cancel.saved.isEmpty)
}

/// Suspends inside `write` until released, so a test can act while a save is in flight.
private actor GatedStore: DocumentFileStore {
    private var gate: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?
    private var hasStarted = false
    private(set) var written: [String] = []

    func read(path: String, maximumBytes: Int) async throws -> LoadedFile { throw FileStoreError.notFound }

    func write(_ snapshot: DocumentSnapshot, expecting: SaveExpectation) async throws -> FileRevision {
        written.append(snapshot.text)
        hasStarted = true
        started?.resume()
        await withCheckedContinuation { gate = $0 }
        return .stub(Int64(snapshot.version))
    }

    func waitUntilWriting() async {
        if hasStarted { return }
        await withCheckedContinuation { started = $0 }
    }

    func release() { gate?.resume(); gate = nil }
}

@Test @MainActor
func saveThenCloseWhenTheDocumentIsClean() async throws {
    let store = MemoryDocumentFileStore()
    let useCase = SaveDocumentUseCase(store: store)
    let session = try dirtySession()
    let coordinator = UnsavedChangesCoordinator(
        prompt: { _ in .save },
        save: { session in (try? await useCase.execute(document: session)) != nil }
    )
    #expect(await coordinator.canClose(session))
    #expect(!session.isDirty)
    #expect(await store.text(at: "Main.swift") == "edited")
}

@Test @MainActor
func textTypedWhileSavingKeepsTheWindowOpen() async throws {
    let store = GatedStore()
    let useCase = SaveDocumentUseCase(store: store)
    let session = try dirtySession()
    // The user keeps typing after choosing Save: version 2 appears while version 1 is written.
    let coordinator = UnsavedChangesCoordinator(
        prompt: { _ in .save },
        save: { session in
            let write = Task { try await useCase.execute(document: session) }
            await store.waitUntilWriting()
            try? session.replaceText("typed during save", expectedVersion: session.version)
            await store.release()
            return (try? await write.value) != nil
        }
    )
    #expect(!(await coordinator.canClose(session)), "the write succeeded but its result is already stale")
    #expect(session.isDirty)
    #expect(session.text == "typed during save")
    #expect(await store.written == ["edited"])
}

@Test @MainActor
func failedSaveKeepsTheDocument() async throws {
    let script = Script(.save)
    script.saveResult = false
    #expect(!(await script.coordinator().canClose(try dirtySession())))
    #expect(script.saved == ["Main.swift"])
}

@Test @MainActor
func aSecondCloseWhileThePromptIsOpenDoesNotStackAnotherPrompt() async throws {
    var release: CheckedContinuation<UnsavedChangesDecision, Never>?
    var promptCount = 0
    let coordinator = UnsavedChangesCoordinator(
        prompt: { _ in
            promptCount += 1
            return await withCheckedContinuation { release = $0 }
        },
        save: { _ in true }
    )
    let session = try dirtySession()
    let first = Task { await coordinator.canClose(session) }
    await Task.yield()
    #expect(!(await coordinator.canClose(session)))
    #expect(promptCount == 1)
    release?.resume(returning: .discard)
    #expect(await first.value)
}

// MARK: Quit

@Test @MainActor
func quitAsksOnlyAboutDirtyDocumentsAndStopsAtTheFirstCancel() async throws {
    let script = Script(.discard)
    let clean = DocumentSession(path: "Clean.swift", backend: StringDocumentBackend(loadedText: "x"))
    let a = try dirtySession("A.swift")
    let b = try dirtySession("B.swift")
    let c = try dirtySession("C.swift")

    #expect(await script.coordinator().canQuit(documents: { [clean, a, b, c] }))
    #expect(script.prompted == ["A.swift", "B.swift", "C.swift"])

    let stopping = Script(.cancel)
    #expect(!(await stopping.coordinator().canQuit(documents: { [clean, a, b, c] })))
    #expect(stopping.prompted == ["A.swift"], "no further questions after the user cancelled")
}

@Test @MainActor
func quitIsRefusedWhenAnyDocumentCannotBeSaved() async throws {
    let script = Script(.save)
    script.saveResult = false
    let a = try dirtySession("A.swift")
    let b = try dirtySession("B.swift")
    #expect(!(await script.coordinator().canQuit(documents: { [a, b] })))
    #expect(script.saved == ["A.swift"])
}

@Test @MainActor
func quitWithNothingUnsavedNeedsNoQuestion() async {
    let script = Script(.cancel)
    let clean = DocumentSession(path: "Clean.swift", backend: StringDocumentBackend(loadedText: "x"))
    #expect(await script.coordinator().canQuit(documents: { [clean] }))
    #expect(script.prompted.isEmpty)
}

// MARK: Quit while the world moves

@Test @MainActor
func aCleanDocumentEditedDuringAnotherQuestionIsAskedAboutBeforeQuitting() async throws {
    let a = DocumentSession(path: "A.swift", backend: StringDocumentBackend(loadedText: "x"))   // clean
    let b = try dirtySession("B.swift")
    var prompted: [String] = []
    let coordinator = UnsavedChangesCoordinator(
        prompt: { session in
            prompted.append(session.path)
            // While the sheet for B is open, A is changed (another window, a command).
            if session.path == "B.swift", a.version == 0 { try? a.replaceText("late edit", expectedVersion: 0) }
            return .discard
        },
        save: { _ in true }
    )
    #expect(await coordinator.canQuit(documents: { [a, b] }))
    #expect(prompted == ["B.swift", "A.swift"], "A became dirty after it had been looked at")
}

@Test @MainActor
func refusingTheLateQuestionKeepsTheAppRunning() async throws {
    let a = DocumentSession(path: "A.swift", backend: StringDocumentBackend(loadedText: "x"))
    let b = try dirtySession("B.swift")
    let coordinator = UnsavedChangesCoordinator(
        prompt: { session in
            if session.path == "B.swift" { try? a.replaceText("late edit", expectedVersion: 0); return .discard }
            return .cancel
        },
        save: { _ in true }
    )
    #expect(!(await coordinator.canQuit(documents: { [a, b] })))
    #expect(a.isDirty)
}

@Test @MainActor
func aSavedDocumentEditedAgainDuringAnotherQuestionIsAskedAgain() async throws {
    let store = MemoryDocumentFileStore()
    let useCase = SaveDocumentUseCase(store: store)
    let a = try dirtySession("A.swift")
    let b = try dirtySession("B.swift")
    var prompted: [String] = []
    var editedAgain = false
    let coordinator = UnsavedChangesCoordinator(
        prompt: { session in
            prompted.append(session.path)
            if session.path == "B.swift", !editedAgain {
                editedAgain = true
                try? a.replaceText("edited after its save", expectedVersion: a.version)
                return .discard
            }
            return session.path == "A.swift" && prompted.count == 1 ? .save : .discard
        },
        save: { session in (try? await useCase.execute(document: session)) != nil }
    )
    #expect(await coordinator.canQuit(documents: { [a, b] }))
    #expect(prompted == ["A.swift", "B.swift", "A.swift"])
    #expect(await store.text(at: "A.swift") == "edited")
}

@Test @MainActor
func aWindowOpenedDuringAQuestionIsIncluded() async throws {
    let a = try dirtySession("A.swift")
    var open = [a]
    var prompted: [String] = []
    let coordinator = UnsavedChangesCoordinator(
        prompt: { session in
            prompted.append(session.path)
            if session.path == "A.swift", open.count == 1 {
                open.append((try? dirtySession("New.swift"))!)
            }
            return .discard
        },
        save: { _ in true }
    )
    #expect(await coordinator.canQuit(documents: { open }))
    #expect(prompted == ["A.swift", "New.swift"])
}

@Test @MainActor
func discardingOneVersionDoesNotAskAgainWhileNothingChanged() async throws {
    let a = try dirtySession("A.swift")
    let b = try dirtySession("B.swift")
    var prompted: [String] = []
    let coordinator = UnsavedChangesCoordinator(
        prompt: { session in prompted.append(session.path); return .discard },
        save: { _ in true }
    )
    #expect(await coordinator.canQuit(documents: { [a, b] }))
    #expect(prompted == ["A.swift", "B.swift"], "each document once")
}

@Test @MainActor
func discardOnlyCoversTheVersionTheUserSawWhenClosingAWindow() async throws {
    let a = try dirtySession("A.swift")
    let coordinator = UnsavedChangesCoordinator(
        prompt: { session in
            try? session.replaceText("changed under the sheet", expectedVersion: session.version)
            return .discard
        },
        save: { _ in true }
    )
    #expect(!(await coordinator.canClose(a)), "the answer was about older text")
}

@Test @MainActor
func discardingADocumentDoesNotCoverEditsMadeAfterwards() async throws {
    let a = try dirtySession("A.swift")
    let b = try dirtySession("B.swift")
    var prompted: [String] = []
    var editedA = false
    let coordinator = UnsavedChangesCoordinator(
        prompt: { session in
            prompted.append(session.path)
            // A was already given up. Then, while B is asked about, A gets new text.
            if session.path == "B.swift", !editedA {
                editedA = true
                try? a.replaceText("typed after Don’t Save", expectedVersion: a.version)
            }
            return .discard
        },
        save: { _ in true }
    )
    #expect(await coordinator.canQuit(documents: { [a, b] }))
    #expect(prompted == ["A.swift", "B.swift", "A.swift"], "new text in A is a new question")
}

// MARK: Quit: letting go of recovery copies takes time, and the world moves meanwhile

@MainActor
private final class QuitLog {
    var released: [[String]] = []
    var reinstated: [[String]] = []
}

@Test @MainActor
func quitReleasesTheDocumentsTheUserAgreedToLoseBeforeSayingYes() async throws {
    let script = Script(.discard)
    let clean = DocumentSession(path: "Clean.swift", backend: StringDocumentBackend(loadedText: "x"))
    let a = try dirtySession("A.swift")
    let log = QuitLog()
    let allowed = await script.coordinator().canQuit(
        documents: { [clean, a] },
        release: { log.released.append($0.map(\.path)) },
        reinstate: { log.reinstated.append($0.map(\.path)) }
    )
    #expect(allowed)
    #expect(log.released == [["A.swift"]])
    #expect(log.reinstated.isEmpty)
}

@Test @MainActor
func textTypedWhileTheCopiesAreBeingReleasedIsAskedAboutAgain() async throws {
    let script = Script(.discard)
    let a = try dirtySession("A.swift")
    let log = QuitLog()
    var typed = false
    let allowed = await script.coordinator().canQuit(
        documents: { [a] },
        release: { sessions in
            log.released.append(sessions.map(\.path))
            await Task.yield()
            if !typed {
                typed = true
                try? a.replaceText("typed while releasing", expectedVersion: a.version)
            }
        },
        reinstate: { log.reinstated.append($0.map(\.path)) }
    )
    #expect(allowed)
    #expect(script.prompted == ["A.swift", "A.swift"], "the answer covered the old text only")
    #expect(log.released == [["A.swift"], ["A.swift"]], "its copy is released again for the new text")
}

@Test @MainActor
func aWindowThatAppearedWhileReleasingIsAskedAbout() async throws {
    let script = Script(.discard)
    let a = try dirtySession("A.swift")
    let late = try dirtySession("Late.swift")
    var open = [a]
    let log = QuitLog()
    let allowed = await script.coordinator().canQuit(
        documents: { open },
        release: { sessions in
            log.released.append(sessions.map(\.path))
            await Task.yield()
            if open.count == 1 { open.append(late) }
        },
        reinstate: { log.reinstated.append($0.map(\.path)) }
    )
    #expect(allowed)
    #expect(script.prompted == ["A.swift", "Late.swift"])
    #expect(log.released == [["A.swift"], ["Late.swift"]])
}

@Test @MainActor
func refusingAfterDocumentsWereReleasedPutsTheirProtectionBack() async throws {
    var answers: [UnsavedChangesDecision] = [.discard, .cancel]
    var prompted: [String] = []
    let coordinator = UnsavedChangesCoordinator(
        prompt: { session in
            prompted.append(session.path)
            return answers.removeFirst()
        },
        save: { _ in true }
    )
    let a = try dirtySession("A.swift")
    var typed = false
    let log = QuitLog()
    let allowed = await coordinator.canQuit(
        documents: { [a] },
        release: { sessions in
            log.released.append(sessions.map(\.path))
            await Task.yield()
            if !typed {
                typed = true
                try? a.replaceText("typed while releasing", expectedVersion: a.version)
            }
        },
        reinstate: { log.reinstated.append($0.map(\.path)) }
    )
    #expect(!allowed, "the user cancelled the second question")
    #expect(log.reinstated == [["A.swift"]], "the app goes on, so the copy of A must be kept again")
}

@Test @MainActor
func nothingIsReleasedWhenTheUserCancelsFirst() async throws {
    let script = Script(.cancel)
    let a = try dirtySession("A.swift")
    let log = QuitLog()
    let allowed = await script.coordinator().canQuit(
        documents: { [a] },
        release: { log.released.append($0.map(\.path)) },
        reinstate: { log.reinstated.append($0.map(\.path)) }
    )
    #expect(!allowed)
    #expect(log.released.isEmpty && log.reinstated.isEmpty)
}
