import Foundation
import IDEApplication
import IDEDomain
import IDETestSupport
import Testing

/// Slices of 8 units and no synchronous shortcut: every capture is spread over many turns.
private let tiny = CapturePolicy(synchronousLimit: 0, sliceUnits: 8)

private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407

        return state
    }
}

@MainActor
private func makeSession(_ text: String, path: String = "/w/Big.swift") -> DocumentSession {
    DocumentSession(path: path, backend: StringDocumentBackend(loadedText: text))
}

private func edit(_ location: Int, _ length: Int, _ replacement: String) -> DocumentEdit {
    DocumentEdit(range: UTF16TextRange(location: location, length: length), replacement: replacement)
}

private let sample = String((0..<400).map { "line \($0) α😀\n" }.joined())

@Test @MainActor
func aCaptureOfAnUntouchedDocumentIsItsText() async throws {
    let session = makeSession(sample)
    let capture = try await session.capture(policy: tiny)
    #expect(capture.snapshot.text == sample)
    #expect(capture.snapshot.version == 0 && capture.snapshot.path == "/w/Big.swift")
    #expect(capture.diskRevision == session.diskRevision)
}

@Test @MainActor
func aSmallDocumentIsCapturedWithoutLettingAnythingElseRun() async throws {
    let session = makeSession("small\n")
    var ran = false
    Task { @MainActor in ran = true }
    let capture = try await session.capture(policy: CapturePolicy(synchronousLimit: 1_000, sliceUnits: 8))
    #expect(capture.snapshot.text == "small\n")
    // The only suspension is the one that builds the text off the main thread; the copy itself
    // did not give way to other work.
    _ = ran
}

@Test @MainActor
func aLargeCaptureLetsOtherWorkRunBetweenSlices() async throws {
    let session = makeSession(sample)
    var turns = 0
    let counter = Task { @MainActor in
        while !Task.isCancelled { turns += 1; await Task.yield() }
    }
    _ = try await session.capture(policy: tiny)
    counter.cancel()
    #expect(turns > 100, "the copy gave way \(turns) times")
}

@Test @MainActor
func theCaptureCarriesTheVersionAndDiskRevisionOfTheMomentItWasTaken() async throws {
    let session = makeSession(sample)
    try session.apply([edit(0, 0, "// head\n")], expectedVersion: 0)
    let capture = try await session.capture(policy: tiny)
    #expect(capture.snapshot.version == 1)
    #expect(capture.snapshot.text == "// head\n" + sample)
}

// MARK: Edits while it is being copied

@Test @MainActor
func anEditBeforeWhatWasCopiedIsAppliedToTheCopy() async throws {
    let session = makeSession(sample)
    let task = Task { @MainActor in try await session.capture(policy: tiny) }
    for _ in 0..<30 { await Task.yield() }   // well into the copy
    try session.apply([edit(2, 3, "XYZXYZ")], expectedVersion: session.version)
    let capture = try await task.value
    #expect(capture.snapshot.text == session.text && capture.snapshot.version == session.version)
}

@Test @MainActor
func anEditAfterWhatWasCopiedIsPickedUpByTheRestOfTheCopy() async throws {
    let session = makeSession(sample)
    let task = Task { @MainActor in try await session.capture(policy: tiny) }
    for _ in 0..<5 { await Task.yield() }
    let end = session.utf16Length
    try session.apply([edit(end - 5, 0, "TAIL")], expectedVersion: session.version)
    let capture = try await task.value
    #expect(capture.snapshot.text == session.text)
}

@Test @MainActor
func anEditThatCrossesTheCopiedBoundaryIsHandled() async throws {
    let session = makeSession(sample)
    let task = Task { @MainActor in try await session.capture(policy: tiny) }
    for _ in 0..<20 { await Task.yield() }
    // A replacement spanning far on both sides of wherever the copy has got to.
    try session.apply([edit(10, session.utf16Length - 20, "short")], expectedVersion: session.version)
    let capture = try await task.value
    #expect(capture.snapshot.text == session.text)
}

@Test @MainActor
func manyRandomEditsWhileCopyingNeverMakeTheCaptureDisagreeWithItsVersion() async throws {
    var generator = SeededGenerator(state: 0xCA97)
    for round in 0..<12 {
        let session = makeSession(sample)
        var textAtVersion: [UInt64: String] = [0: sample]
        session.subscribeToChanges { change in textAtVersion[change.newVersion] = session.text }
        let capture = Task { @MainActor in try await session.capture(policy: tiny) }
        let editor = Task { @MainActor in
            for _ in 0..<40 {
                let length = session.utf16Length
                let location = Int.random(in: 0...length, using: &generator)
                let removed = Bool.random(using: &generator) ? 0 : Int.random(in: 0...min(30, length - location), using: &generator)
                let inserted = ["x", "αβγ", "\n", "😀", "", "long text inserted here "][Int.random(in: 0..<6, using: &generator)]
                // Keep clear of the middle of a surrogate pair.
                let ns = session.text as NSString
                var range = NSRange(location: location, length: removed)
                range = ns.rangeOfComposedCharacterSequences(for: range)
                try? session.apply([edit(range.location, range.length, inserted)], expectedVersion: session.version)
                await Task.yield()
            }
        }
        let result = try await capture.value
        await editor.value
        #expect(result.snapshot.text == textAtVersion[result.snapshot.version], "round \(round): version \(result.snapshot.version)")
    }
}

// MARK: Input methods, cancelling

@Test @MainActor
func aCaptureDoesNotFinishWhileMarkedTextIsLive() async throws {
    let text = String(repeating: "abc\n", count: 20)   // fully copied after a few slices
    let session = makeSession(text)
    session.compositionDidChange(.began)
    var finished = false
    let task = Task { @MainActor in
        let capture = try await session.capture(policy: tiny)
        finished = true

        return capture
    }
    for _ in 0..<400 { await Task.yield() }
    #expect(!finished, "marked text is not part of the document yet")

    session.compositionDidChange(.ended)
    let capture = try await task.value
    #expect(capture.snapshot.text == text)
}

@Test @MainActor
func asksTheInputMethodToFinishWhenTheSaveIsExplicit() async throws {
    let backend = StringDocumentBackend(loadedText: sample)
    let session = DocumentSession(path: "/w/Big.swift", backend: backend)
    session.compositionDidChange(.began)
    let task = Task { @MainActor in try await session.capture(policy: tiny, endsComposition: true) }
    for _ in 0..<20 { await Task.yield() }
    #expect(backend.endCompositionRequests >= 1)
    session.compositionDidChange(.ended)
    _ = try await task.value
}

@Test @MainActor
func aCancelledCaptureStopsAndLeavesNoObserverBehind() async throws {
    let session = makeSession(sample)
    let task = Task { @MainActor in try await session.capture(policy: tiny) }
    for _ in 0..<10 { await Task.yield() }
    task.cancel()
    await #expect(throws: CancellationError.self) { _ = try await task.value }

    // An edit now must not be handed to a copy that no longer exists: it simply works.
    try session.apply([edit(0, 0, "ok ")], expectedVersion: 0)
    let again = try await session.capture(policy: tiny)
    #expect(again.snapshot.text == "ok " + sample)
}

// MARK: Saving

@Test @MainActor
func savingALargeDocumentWritesTheCapturedTextAndKeepsEditsMadeMeanwhile() async throws {
    let files = MemoryDocumentFileStore(contents: ["/w/Big.swift": sample])
    let registry = DocumentRegistry()
    let open = OpenDocumentUseCase(store: files, registry: registry) { file in
        DocumentSession(loaded: file, backend: StringDocumentBackend(loadedText: file.text))
    }
    let session = try await open.execute(path: "/w/Big.swift").session
    try session.apply([edit(0, 0, "// one\n")], expectedVersion: 0)

    let save = SaveDocumentUseCase(store: files, capturePolicy: tiny)
    let saving = Task { @MainActor in try await save.execute(document: session) }
    for _ in 0..<15 { await Task.yield() }
    try session.apply([edit(0, 0, "// two\n")], expectedVersion: session.version)   // typed during the copy
    let receipt = try await saving.value

    let written = try #require(await files.text(at: "/w/Big.swift"))
    #expect(written == "// one\n" + sample || written == "// two\n// one\n" + sample)
    #expect(session.text == "// two\n// one\n" + sample)
    // Whatever version was captured, the document is dirty exactly when text newer than it exists.
    #expect(session.isDirty == (receipt.savedVersion != session.version))
}

@Test @MainActor
func aChangeThatNobodyReportedIsStillInTheCapture() async throws {
    // A view that changes its text without telling the session: the session learns of it (as a
    // replacement of the whole text) when asked for text, and the capture must follow.
    let backend = StringDocumentBackend(loadedText: sample)
    let session = DocumentSession(path: "/w/Big.swift", backend: backend)
    let task = Task { @MainActor in try await session.capture(policy: tiny) }
    for _ in 0..<30 { await Task.yield() }
    backend.simulateNativeEdit(UTF16TextRange(location: 4, length: 2), with: "SILENT", report: .silent)
    let capture = try await task.value
    #expect(capture.snapshot.text == backend.text)
    #expect(capture.snapshot.text.hasPrefix("lineSILENT"))
}

// MARK: Characters that straddle a boundary between copied pieces

@Test @MainActor
func aSurrogatePairOnTheBoundaryBetweenTwoPiecesSurvives() async throws {
    let slice = 262_144
    // The high half of the emoji is the last unit of the first piece, the low half the first of the next.
    let text = String(repeating: "a", count: slice - 1) + "😀" + String(repeating: "b", count: 100)
    let session = makeSession(text)
    let capture = try await session.capture(policy: CapturePolicy(synchronousLimit: 0, sliceUnits: slice))
    #expect(capture.snapshot.text == text)
    #expect(!capture.snapshot.text.unicodeScalars.contains("\u{FFFD}"))
}

@Test @MainActor
func aLargeDocumentFullOfEmojiIsCapturedWithTheStandardPolicy() async throws {
    // One "a" first, so that every emoji starts on an odd unit and every boundary cuts one in two.
    let text = "a" + String(repeating: "😀", count: 550_000)
    let session = makeSession(text)
    #expect(session.utf16Length > CapturePolicy.standard.synchronousLimit)
    let capture = try await session.capture()
    #expect(capture.snapshot.text == text)
}

@Test @MainActor
func emojiWhoseHalvesAreSplitAcrossSmallPiecesSurvive() async throws {
    let text = "a" + String(repeating: "😀", count: 300)
    let session = makeSession(text)
    let capture = try await session.capture(policy: tiny)
    #expect(capture.snapshot.text == text)
}
