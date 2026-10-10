import Foundation
import IDEApplication
import IDEDomain
import IDETestSupport
import Testing
@testable import LanguageInfrastructure

private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407

        return state
    }
}

@MainActor
private final class Rig {
    let server = ScriptedServer()
    let connection: LanguageServerConnection
    let sync: OrderedDocumentSync
    let session: DocumentSession
    let backend: StringDocumentBackend

    init(
        text: String = "let a = 1\nlet b = 2\n",
        path: String = "/w/Main.swift",
        limits: OrderedDocumentSync.Limits = .init(),
        capture: CapturePolicy = .standard
    ) {
        connection = LanguageServerConnection(channel: server, onNotification: { _, _ in })
        sync = OrderedDocumentSync(limits: limits, capturePolicy: capture)
        backend = StringDocumentBackend(loadedText: text)
        session = DocumentSession(path: path, backend: backend)
        uri = URL(fileURLWithPath: path).absoluteString
        sync.attach(connection)
    }

    let uri: String
    func model() -> LSPDocumentModel { server.model() }

    /// Waits until what the server would believe is the session's text, and checks nothing the
    /// server was told made no sense.
    func serverCatchesUp(sourceLocation: SourceLocation = #_sourceLocation) async -> Bool {
        let expected = session.text
        let server = server, uri = uri
        let caught = await server.waitUntil { server.model().text(uri) == expected }
        #expect(model().problems.isEmpty, "\(model().problems)", sourceLocation: sourceLocation)

        return caught
    }

    func edit(_ location: Int, _ length: Int, _ text: String) throws {
        try session.apply(
            [DocumentEdit(range: UTF16TextRange(location: location, length: length), replacement: text)],
            expectedVersion: session.version
        )
    }
}

// MARK: Opening

@Test @MainActor
func openingSendsTheTextVersionAndAddress() async throws {
    let rig = Rig(text: "let ü = \"😀\"\n")
    try await rig.sync.open(rig.session)
    #expect(await rig.server.waitForMethod("textDocument/didOpen"))
    let opened = try #require(rig.server.messages(named: "textDocument/didOpen").first?["params"]?["textDocument"])
    #expect(opened["uri"]?.stringValue == "file:///w/Main.swift")
    #expect(opened["languageId"]?.stringValue == "swift")
    #expect(opened["version"] == .int(0))
    #expect(opened["text"]?.stringValue == "let ü = \"😀\"\n")
    #expect(rig.sync.isSynced(rig.session))
}

@Test @MainActor
func documentsTheServerCannotUseAreRefusedWithAReason() async throws {
    let rig = Rig()
    let untitled = DocumentSession(path: "Untitled.swift", backend: StringDocumentBackend(loadedText: "x"), isUntitled: true)
    await #expect(throws: DocumentSyncError.untitled) { try await rig.sync.open(untitled) }
    let notes = DocumentSession(path: "/w/notes.txt", backend: StringDocumentBackend(loadedText: "x"))
    await #expect(throws: DocumentSyncError.unsupportedLanguage) { try await rig.sync.open(notes) }

    let small = Rig(text: String(repeating: "a", count: 100), limits: .init(maximumUTF16Length: 50))
    await #expect(throws: DocumentSyncError.tooLarge(utf16Length: 100, limit: 50)) { try await small.sync.open(small.session) }

    try await rig.sync.open(rig.session)
    await #expect(throws: DocumentSyncError.alreadyOpen) { try await rig.sync.open(rig.session) }
    #expect(await rig.server.waitForMethod("textDocument/didOpen"))
    #expect(rig.server.methods == ["textDocument/didOpen"], "refused documents were not announced")
}

// MARK: Changes

@Test @MainActor
func anEditIsSentAsARangeInTheTextBeforeIt() async throws {
    let rig = Rig(text: "let a = 1\nlet b = 2\n")
    try await rig.sync.open(rig.session)
    try rig.edit(14, 1, "beta")   // "b" on the second line
    #expect(await rig.server.waitForMethod("textDocument/didChange"))
    let change = try #require(rig.server.messages(named: "textDocument/didChange").first?["params"])
    #expect(change["textDocument"]?["version"] == .int(1))
    #expect(change["contentChanges"]?[0]?["range"]?["start"] == ["line": 1, "character": 4])
    #expect(change["contentChanges"]?[0]?["range"]?["end"] == ["line": 1, "character": 5])
    #expect(change["contentChanges"]?[0]?["text"]?.stringValue == "beta")
}

@Test @MainActor
func severalEditsOfOneTransactionAreSentRightToLeftSoEveryRangeHolds() async throws {
    let rig = Rig(text: "one\ntwo\nthree\n")
    try await rig.sync.open(rig.session)
    try rig.session.apply([
        DocumentEdit(range: UTF16TextRange(location: 0, length: 3), replacement: "1"),
        DocumentEdit(range: UTF16TextRange(location: 4, length: 3), replacement: "2\n2"),
        DocumentEdit(range: UTF16TextRange(location: 8, length: 5), replacement: ""),
    ], expectedVersion: 0)
    #expect(await rig.serverCatchesUp())
}

@Test @MainActor
func manyRandomEditsLeaveTheServerWithExactlyTheDocument() async throws {
    var generator = SeededGenerator(state: 0x5EED)
    let pieces = ["x", "αβ", "\n", "\r\n", "😀", "", "let value = 1", "\r"]
    for round in 0..<10 {
        let rig = Rig(text: "first\nsecond 😀\r\nthird\n", path: "/w/Round\(round).swift")
        try await rig.sync.open(rig.session)
        for _ in 0..<60 {
            let ns = rig.session.text as NSString
            let length = ns.length
            let count = Int.random(in: 1...3, using: &generator)
            var cuts = (0..<count * 2).map { _ in Int.random(in: 0...length, using: &generator) }.sorted()
            var edits: [DocumentEdit] = []
            var floor = 0
            while cuts.count >= 2 {
                let lo = max(cuts.removeFirst(), floor), hi = max(cuts.removeFirst(), lo)
                var range = ns.rangeOfComposedCharacterSequences(for: NSRange(location: lo, length: hi - lo))
                if range.location < floor { range = NSRange(location: floor, length: max(0, range.upperBound - floor)) }
                edits.append(DocumentEdit(range: UTF16TextRange(location: range.location, length: range.length), replacement: pieces.randomElement(using: &generator)!))
                floor = range.upperBound
                if edits.count > 1, edits[edits.count - 1].range.location == edits[edits.count - 2].range.location + edits[edits.count - 2].range.length, edits[edits.count - 1].range.length == 0, edits[edits.count - 2].range.length == 0 {
                    edits.removeLast()   // two insertions at one place are not allowed in a transaction
                }
            }
            try? rig.session.apply(edits, expectedVersion: rig.session.version)
        }
        #expect(await rig.serverCatchesUp(), "round \(round)")
        #expect(rig.sync.resyncCount == 0, "followed incrementally the whole time")
    }
}

@Test @MainActor
func versionsGoUpByTheDocumentsVersions() async throws {
    let rig = Rig()
    try await rig.sync.open(rig.session)
    try rig.edit(0, 0, "a")
    try rig.edit(0, 0, "b")
    try rig.edit(0, 0, "c")
    #expect(await rig.server.waitForMethod("textDocument/didChange", count: 3))
    let versions = rig.server.messages(named: "textDocument/didChange").compactMap { $0["params"]?["textDocument"]?["version"]?.intValue }
    #expect(versions == [1, 2, 3])
}

@Test @MainActor
func editsMadeWhileTheTextIsBeingCopiedFollowTheOpening() async throws {
    // Slices of 8 units: the copy of this text takes many turns of the main thread.
    let rig = Rig(text: String(repeating: "line of text\n", count: 200), capture: CapturePolicy(synchronousLimit: 0, sliceUnits: 8))
    let opening = Task { @MainActor in try await rig.sync.open(rig.session) }
    for _ in 0..<25 { await Task.yield() }
    try rig.edit(3, 0, "<one>")
    try rig.edit(0, 0, "<two>")
    try await opening.value
    #expect(await rig.serverCatchesUp())
    #expect(rig.server.methods.first == "textDocument/didOpen", "the text goes first, the edits after it")
}

@Test @MainActor
func aChangeNobodyReportedIsStillFollowed() async throws {
    let rig = Rig(text: "alpha beta gamma\n")
    try await rig.sync.open(rig.session)
    rig.backend.simulateNativeEdit(UTF16TextRange(location: 6, length: 4), with: "BETA!", report: .silent)
    _ = rig.session.snapshot()   // the session notices when it is asked for the text
    #expect(await rig.serverCatchesUp())
}

// MARK: Falling behind

@Test @MainActor
func aServerThatDoesNotKeepUpIsGivenOneFullTextInsteadOfTheEditsItMissed() async throws {
    let rig = Rig(text: "start\n", limits: .init(maximumPendingMessages: 5))
    try await rig.sync.open(rig.session)
    #expect(await rig.server.waitForMethod("textDocument/didOpen"))
    rig.server.hold()
    for i in 0..<60 { try rig.edit(0, 0, "\(i);") }
    #expect(rig.sync.resyncCount >= 1)
    rig.server.release()
    #expect(await rig.serverCatchesUp())
    let changes = rig.server.messages(named: "textDocument/didChange").count
    #expect(changes < 60, "\(changes) messages for 60 edits: the missed ones were folded into a full text")
    // And it goes on incrementally afterwards.
    let before = rig.server.messages(named: "textDocument/didChange").count
    try rig.edit(0, 0, "after")
    #expect(await rig.serverCatchesUp())
    let last = try #require(rig.server.messages(named: "textDocument/didChange").last?["params"]?["contentChanges"]?[0])
    #expect(rig.server.messages(named: "textDocument/didChange").count == before + 1)
    #expect(last["range"] != nil, "back to ranges")
}

// MARK: Other lifecycles

@Test @MainActor
func closingTellsTheServerAndStopsFollowing() async throws {
    let rig = Rig()
    try await rig.sync.open(rig.session)
    rig.sync.close(rig.session)
    try rig.edit(0, 0, "ignored")
    #expect(await rig.server.waitForMethod("textDocument/didClose"))
    try await Task.sleep(for: .milliseconds(30))
    #expect(rig.server.methods == ["textDocument/didOpen", "textDocument/didClose"])
}

@Test @MainActor
func savingUnderAnotherNameClosesTheOldAddressAndOpensTheNew() async throws {
    let files = MemoryDocumentFileStore(contents: ["/w/Old.swift": "let x = 1\n"])
    let registry = DocumentRegistry()
    let open = OpenDocumentUseCase(store: files, registry: registry) { file in
        DocumentSession(loaded: file, backend: StringDocumentBackend(loadedText: file.text))
    }
    let session = try await open.execute(path: "/w/Old.swift").session
    let server = ScriptedServer()
    let connection = LanguageServerConnection(channel: server, onNotification: { _, _ in })
    let sync = OrderedDocumentSync()
    sync.attach(connection)
    try await sync.open(session)

    try session.replaceText("let x = 2\n", expectedVersion: 0)
    _ = try await SaveDocumentUseCase(store: files).saveAs(document: session, to: "/w/New.swift", target: .newFile, registry: registry)

    #expect(await server.waitForMethod("textDocument/didOpen", count: 2))
    var model = LSPDocumentModel()
    for message in server.received { model.consume(message) }
    #expect(model.text("file:///w/Old.swift") == nil, "closed at the old address")
    #expect(model.text("file:///w/New.swift") == "let x = 2\n")
    // The new address is followed.
    try session.apply([DocumentEdit(range: UTF16TextRange(location: 0, length: 0), replacement: "// c\n")], expectedVersion: session.version)
    #expect(await server.waitUntil {
        var m = LSPDocumentModel()
        for message in server.received { m.consume(message) }

        return m.text("file:///w/New.swift") == "// c\nlet x = 2\n"
    })
}

@Test @MainActor
func aDocumentClosedRightAfterSaveAsIsNotClosedTwiceAtTheOldAddress() async throws {
    let files = MemoryDocumentFileStore(contents: ["/w/Old.swift": "let x = 1\n"])
    let registry = DocumentRegistry()
    let open = OpenDocumentUseCase(store: files, registry: registry) { file in
        DocumentSession(loaded: file, backend: StringDocumentBackend(loadedText: file.text))
    }
    let session = try await open.execute(path: "/w/Old.swift").session
    let server = ScriptedServer()
    let sync = OrderedDocumentSync()
    sync.attach(LanguageServerConnection(channel: server, onNotification: { _, _ in }))
    try await sync.open(session)

    _ = try await SaveDocumentUseCase(store: files).saveAs(document: session, to: "/w/New.swift", target: .newFile, registry: registry)
    sync.close(session)    // before the new address was opened
    try await Task.sleep(for: .milliseconds(50))

    #expect(server.messages(named: "textDocument/didClose").count == 1, "the old address, once")
    #expect(server.messages(named: "textDocument/didOpen").count == 1, "and the new one is never opened for a document that was closed")
}

@Test @MainActor
func aDocumentClosedBeforeItWasOpenedOnTheServerSaysNothingToIt() async throws {
    let rig = Rig()
    let opening = Task { @MainActor in try await rig.sync.open(rig.session) }
    while !rig.sync.openDocuments.contains(where: { $0.id == rig.session.id }) { await Task.yield() }
    rig.sync.close(rig.session)
    _ = try? await opening.value
    try await Task.sleep(for: .milliseconds(50))
    #expect(rig.server.messages(named: "textDocument/didClose").isEmpty, "there was no document there to close")
}

// MARK: Order against requests

@Test @MainActor
func aRequestMadeAfterEditsReachesTheServerAfterThemAndAboutTheirText() async throws {
    let rig = Rig(text: "a.\n")
    try await rig.sync.open(rig.session)
    try rig.edit(0, 0, "let x = 1\n")
    try rig.edit(10, 1, "x")
    let position = try #require(rig.sync.position(of: 11, in: rig.session))
    _ = rig.connection.request("probe", ["line": .int(position.line), "character": .int(position.character)])
    #expect(await rig.server.waitForMethod("probe"))
    #expect(rig.server.methods == ["textDocument/didOpen", "textDocument/didChange", "textDocument/didChange", "probe"])
    #expect(position == LSPPosition(line: 1, character: 1))
    #expect(await rig.serverCatchesUp())
}

@Test @MainActor
func aNewServerIsGivenEveryDocumentAgainFromItsCurrentText() async throws {
    let rig = Rig(text: "one\n")
    try await rig.sync.open(rig.session)
    rig.sync.attach(nil)                      // the server is gone
    try rig.edit(0, 0, "typed while it was down ")
    let second = ScriptedServer()
    rig.sync.attach(LanguageServerConnection(channel: second, onNotification: { _, _ in }))
    #expect(await second.waitForMethod("textDocument/didOpen"))
    var model = LSPDocumentModel()
    for message in second.received { model.consume(message) }
    #expect(model.text(rig.uri) == "typed while it was down one\n")
    #expect(model.versions[rig.uri] == 1)
}

// MARK: The one place the protocol has no address

@Test @MainActor
func anEditInsideALineTerminatorIsSentWidenedToTheWholeTerminator() async throws {
    // Each case is (text, location, length, replacement); the position is between a CR and its LF.
    let cases: [(String, Int, Int, String)] = [
        ("a\r\nb", 2, 1, ""),        // deletes only the LF
        ("a\r\nb", 1, 1, ""),        // deletes only the CR
        ("a\r\nb", 2, 0, "X"),       // inserts between them
        ("a\r\nb", 2, 0, "\n"),      // makes a blank line out of a terminator
        ("a\r\nb\r\nc", 2, 3, "-"), // begins inside one terminator, ends inside the next
        ("\r\n\n\u{3b2}\r\r", 1, 1, ""),
    ]
    for (index, (text, location, length, replacement)) in cases.enumerated() {
        let rig = Rig(text: text, path: "/w/Case\(index).swift")
        try await rig.sync.open(rig.session)
        try rig.edit(location, length, replacement)
        #expect(await rig.serverCatchesUp(), "case \(index): \(text.debugDescription) -> \(rig.session.text.debugDescription)")
    }
}

// MARK: Between the copy and the opening

/// A copy of the text that stops, after it has been taken, until the test lets it go: the moment in
/// which the session goes on while the text is on its way to the server.
@MainActor
private final class GatedCopy {
    private var gate: CheckedContinuation<Void, Never>?
    private(set) var taken = false

    func capture(_ session: DocumentSession, _ policy: CapturePolicy) async throws -> DocumentCapture {
        let capture = try await session.capture(policy: policy)
        taken = true
        await withCheckedContinuation { gate = $0 }

        return capture
    }

    func release() { gate?.resume(); gate = nil }
}

@Test @MainActor
func editsMadeAfterTheCopyWasTakenButBeforeTheOpeningAreSentAfterIt() async throws {
    let server = ScriptedServer()
    let connection = LanguageServerConnection(channel: server, onNotification: { _, _ in })
    let copy = GatedCopy()
    let sync = OrderedDocumentSync(limits: .init(), capturePolicy: .standard, capture: { try await copy.capture($0, $1) })
    sync.attach(connection)
    let session = DocumentSession(path: "/w/Gate.swift", backend: StringDocumentBackend(loadedText: "let a = 1\n"))

    let opening = Task { @MainActor in try await sync.open(session) }
    while !copy.taken { await Task.yield() }
    try session.apply([DocumentEdit(range: UTF16TextRange(location: 0, length: 0), replacement: "// one\n")], expectedVersion: 0)
    try session.apply([DocumentEdit(range: UTF16TextRange(location: 0, length: 0), replacement: "// two\n")], expectedVersion: 1)
    copy.release()
    try await opening.value

    #expect(await server.waitUntil { server.model().text("file:///w/Gate.swift") == "// two\n// one\nlet a = 1\n" })
    #expect(server.model().problems.isEmpty)
    #expect(server.messages(named: "textDocument/didOpen").first?["params"]?["textDocument"]?["version"] == .int(0), "the text sent is the one that was copied")
    #expect(sync.resyncCount == 0)
}

// MARK: When a change cannot be followed

@Test @MainActor
func aChangeThatDoesNotFollowOnFromWhatWasSentIsRepairedByAFullText() async throws {
    let rig = Rig(text: "alpha\n")
    try await rig.sync.open(rig.session)
    // Version 5 follows version 0 of nothing the server was told about.
    rig.sync.receive(
        DocumentChangeSet(documentID: rig.session.id,
                          oldVersion: 4,
                          newVersion: 5,
                          edits: [DocumentEdit(range: UTF16TextRange(location: 0, length: 0), replacement: "x")],
                          origin: .command),
        for: rig.session
    )
    #expect(rig.sync.resyncCount == 1)
    try rig.edit(0, 0, "y")   // typing goes on while the full text waits to be written: it is covered by it
    #expect(await rig.serverCatchesUp())
}

@Test @MainActor
func aChangeThatDisagreesWithTheDocumentsLengthIsRepairedByAFullText() async throws {
    let rig = Rig(text: "alpha\n")
    try await rig.sync.open(rig.session)
    // Claims to insert three characters in the session's latest version; the text did not change.
    rig.sync.receive(
        DocumentChangeSet(documentID: rig.session.id,
                          oldVersion: 0,
                          newVersion: 0,
                          edits: [DocumentEdit(range: UTF16TextRange(location: 0, length: 0), replacement: "zzz")],
                          origin: .command),
        for: rig.session
    )
    #expect(rig.sync.resyncCount == 1)
    try rig.edit(0, 0, "y")
    #expect(await rig.serverCatchesUp())
    #expect(rig.server.model().text(rig.uri) == "yalpha\n", "the server has the document, not the claim")
}
