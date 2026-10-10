import Foundation
import IDEApplication
import IDEDomain
import IDETestSupport
import Testing
@testable import LanguageInfrastructure

private final class Supply: @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [ScriptedServer]
    private(set) var made: [ScriptedServer] = []
    private(set) var asked = 0

    init(_ servers: [ScriptedServer]) { queue = servers }

    func next() throws -> ScriptedServer {
        try lock.withLock {
            asked += 1
            guard !queue.isEmpty else { throw LSPError.notRunning }

            let server = queue.removeFirst()
            made.append(server)

            return server
        }
    }
}

@MainActor
private final class Rig {
    let supply: Supply
    let clock = ManualDelayClock()
    let service: SourceKitLanguageService
    let session: DocumentSession
    let backend: StringDocumentBackend
    var caret = 0

    init(
        servers: [ScriptedServer] = [ScriptedServer()],
        text: String = "let x = 1\nx.\n",
        delays: [Duration] = [.seconds(1), .seconds(2)],
        sync: OrderedDocumentSync = OrderedDocumentSync()
    ) {
        supply = Supply(servers)
        let supply = supply
        service = SourceKitLanguageService(
            workspaceRoot: URL(fileURLWithPath: "/w"),
            sync: sync,
            restartPolicy: .init(delays: delays),
            clock: clock,
            channelFactory: { try supply.next() }
        )
        backend = StringDocumentBackend(loadedText: text)
        session = DocumentSession(path: "/w/Main.swift", backend: backend)
        caret = (text as NSString).length
    }

    func started() async throws {
        await service.start()
        try await service.open(session)
        let first = supply.made[0]
        #expect(await first.waitForMethod("textDocument/didOpen"))
    }

    func waitFor(_ timeout: Duration = .seconds(10), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }

        return condition()
    }

    func completion() async -> CompletionOutcome {
        await service.completion(for: session, caret: { self.caret })
    }

    func hover() async -> HoverOutcome {
        await service.hover(for: session, offset: { self.caret })
    }

    func definition() async -> DefinitionOutcome {
        await service.definition(for: session, offset: { self.caret })
    }

    func edit(_ location: Int, _ text: String) throws {
        try session.apply(
            [DocumentEdit(range: UTF16TextRange(location: location, length: 0), replacement: text)],
            expectedVersion: session.version
        )
    }
}

private func completionItem(_ label: String, newText: String? = nil, line: Int = 1, from: Int = 2, to: Int = 2) -> JSONValue {
    var item: [String: JSONValue] = ["label": .string(label), "detail": "Int"]
    if let newText {
        item["textEdit"] = ["range": ["start": ["line": .int(line), "character": .int(from)], "end": ["line": .int(line), "character": .int(to)]], "newText": .string(newText)]
    }

    return .object(item)
}

// MARK: Starting

@Test @MainActor
func theServerIsInitialisedBeforeItIsToldAboutAnyDocument() async throws {
    let held = ScriptedServer(handler: { message, server in
        // Answers nothing: the test decides when `initialize` is answered.
        _ = (message, server)
    })
    let rig = Rig(servers: [held])
    let starting = Task { @MainActor in await rig.service.start() }
    #expect(await held.waitForMethod("initialize"))
    try await rig.service.open(rig.session)
    try await Task.sleep(for: .milliseconds(50))
    #expect(held.methods == ["initialize"], "nothing but initialize may be sent before it is answered")
    #expect(rig.service.state == .starting)

    held.reply(held.messages(named: "initialize")[0]["id"]!, ["capabilities": [:]])
    await starting.value
    #expect(rig.service.state == .running)
    #expect(await held.waitForMethod("textDocument/didOpen"))
    #expect(held.methods == ["initialize", "initialized", "textDocument/didOpen"])
}

@Test @MainActor
func initialiseAsksForUTF16AndVersionedDiagnostics() async throws {
    let rig = Rig()
    await rig.service.start()
    let server = rig.supply.made[0]
    let params = try #require(server.messages(named: "initialize").first?["params"])
    #expect(params["capabilities"]?["general"]?["positionEncodings"] == ["utf-16"])
    #expect(params["capabilities"]?["textDocument"]?["publishDiagnostics"]?["versionSupport"] == true)
    #expect(params["rootUri"]?.stringValue == "file:///w")
}

// MARK: Completion

@Test @MainActor
func completionReturnsTheServersItemsWithTheirReplacementRanges() async throws {
    let server = ScriptedServer(handler: ScriptedServer.standard(completion: [completionItem("bitWidth", newText: "bitWidth"), completionItem("magnitude")]))
    let rig = Rig(servers: [server])
    try await rig.started()
    guard case .items(let items, let incomplete) = await rig.completion() else { Issue.record("expected items"); return }

    #expect(!incomplete)
    #expect(items.map(\.label) == ["bitWidth", "magnitude"])
    #expect(items[0].replacementRange == UTF16TextRange(location: 12, length: 0), "line 1, character 2 of \"let x = 1\\nx.\\n\"")
    #expect(items[1].replacementRange == nil)
    #expect(items[0].detail == "Int")
}

@Test @MainActor
func aLabelWithClangdsLeadingSpaceIsShownWithoutItAndInsertsWithoutIt() async throws {
    let server = ScriptedServer(handler: ScriptedServer.standard(completion: [
        .object(["label": "  clib_add", "filterText": "clib_add", "kind": 3]),
        completionItem(" x", newText: "x"),
        .object(["label": "\u{2022}group_req", "kind": 7]),
        .object(["label": "   "]),
    ]))
    let rig = Rig(servers: [server])
    try await rig.started()
    guard case .items(let items, _) = await rig.completion() else { Issue.record("expected items"); return }

    #expect(items.map(\.label) == ["clib_add", "x", "group_req"], "the empty one is no item; the bullet marks the index")
    #expect(items[0].insertText == "clib_add", "no text edit and no insert text: the name")
    #expect(items[1].insertText == "x")
    #expect(items[0].filterText == "clib_add" && items[0].kind == .function)
}

@Test @MainActor
func anInsertReplaceEditNamesTheReplaceRange() async throws {
    func position(_ character: Int) -> JSONValue { ["line": .int(1), "character": .int(character)] }
    let both: JSONValue = .object([
        "label": "count",
        "textEdit": ["newText": "count", "insert": ["start": position(0), "end": position(1)], "replace": ["start": position(0), "end": position(2)]],
    ])
    let server = ScriptedServer(handler: ScriptedServer.standard(completion: [both]))
    let rig = Rig(servers: [server])
    try await rig.started()
    guard case .items(let items, _) = await rig.completion() else { Issue.record("expected items"); return }

    #expect(items[0].replacementRange == UTF16TextRange(location: 10, length: 2), "the replace range, not the insert one")
}

@Test @MainActor
func completionAskedRightAfterAnEditIsAboutTheEditedText() async throws {
    let server = ScriptedServer(handler: ScriptedServer.standard(completion: [completionItem("member")]))
    let rig = Rig(servers: [server])
    try await rig.started()
    try rig.edit(12, "abc")      // "x.abc"
    rig.caret = 15
    _ = await rig.completion()
    #expect(server.methods.suffix(2) == ["textDocument/didChange", "textDocument/completion"])
    let params = try #require(server.messages(named: "textDocument/completion").first?["params"])
    #expect(params["position"] == ["line": 1, "character": 5])
    #expect(server.model().text("file:///w/Main.swift") == "let x = 1\nx.abc\n")
}

@Test @MainActor
func manyEditsAndACompletionArriveInTheOrderTheyWereMade() async throws {
    let server = ScriptedServer(handler: ScriptedServer.standard(completion: [completionItem("m")]))
    server.slowDown(every: 2, by: .milliseconds(3))
    let rig = Rig(servers: [server], text: "")
    try await rig.started()
    var expected: [String] = []
    for i in 0..<40 {
        try rig.edit(i, "x")
        expected.append("textDocument/didChange")
        if i % 10 == 9 {
            rig.caret = i + 1
            Task { @MainActor in _ = await rig.completion() }
            await Task.yield()
            expected.append("textDocument/completion")
        }
    }
    #expect(await server.waitUntil { server.methods.filter { $0 == "textDocument/completion" }.count == 4 })
    #expect(Array(server.methods.dropFirst(3)) == expected)   // initialize, initialized, didOpen first
    // Each request names the position of the text as it was when it was made.
    let characters = server.messages(named: "textDocument/completion").compactMap { $0["params"]?["position"]?["character"]?.intValue }
    #expect(characters == [10, 20, 30, 40])
}

@Test @MainActor
func anAnswerForTextThatHasChangedSinceIsDropped() async throws {
    let silent = ScriptedServer(handler: { message, server in
        guard let method = message["method"]?.stringValue, let id = message["id"] else { return }

        if method == "initialize" { server.reply(id, ["capabilities": [:]]) }
        // completion: no answer yet
    })
    let rig = Rig(servers: [silent])
    try await rig.started()
    let asking = Task { @MainActor in await rig.completion() }
    #expect(await silent.waitForMethod("textDocument/completion"))
    try rig.edit(0, "// typed meanwhile\n")
    silent.reply(silent.messages(named: "textDocument/completion")[0]["id"]!, ["items": [completionItem("late")]])
    #expect(await asking.value == .stale(.documentChanged))
}

@Test @MainActor
func anAnswerForACaretThatMovedIsDropped() async throws {
    let silent = ScriptedServer(handler: { message, server in
        guard let method = message["method"]?.stringValue, let id = message["id"] else { return }

        if method == "initialize" { server.reply(id, ["capabilities": [:]]) }
    })
    let rig = Rig(servers: [silent])
    try await rig.started()
    let asking = Task { @MainActor in await rig.completion() }
    #expect(await silent.waitForMethod("textDocument/completion"))
    rig.caret = 3
    silent.reply(silent.messages(named: "textDocument/completion")[0]["id"]!, ["items": [completionItem("late")]])
    #expect(await asking.value == .stale(.caretMoved))
}

@Test @MainActor
func completionDoesNotTouchMarkedText() async throws {
    let server = ScriptedServer(handler: ScriptedServer.standard(completion: [completionItem("m")]))
    let rig = Rig(servers: [server])
    try await rig.started()
    rig.session.compositionDidChange(.began)
    #expect(await rig.completion() == .suppressedByComposition)
    #expect(server.messages(named: "textDocument/completion").isEmpty, "nothing was even asked")
    rig.session.compositionDidChange(.ended)
}

@Test @MainActor
func compositionThatBeginsWhileACompletionIsOutMakesItsAnswerStale() async throws {
    let silent = ScriptedServer(handler: { message, server in
        guard let method = message["method"]?.stringValue, let id = message["id"] else { return }

        if method == "initialize" { server.reply(id, ["capabilities": [:]]) }
    })
    let rig = Rig(servers: [silent])
    try await rig.started()
    let asking = Task { @MainActor in await rig.completion() }
    #expect(await silent.waitForMethod("textDocument/completion"))
    rig.session.compositionDidChange(.began)
    silent.reply(silent.messages(named: "textDocument/completion")[0]["id"]!, ["items": [completionItem("late")]])
    #expect(await asking.value == .stale(.compositionStarted))
    rig.session.compositionDidChange(.ended)
}

@Test @MainActor
func cancellingACompletionTellsTheServerAndReportsItStale() async throws {
    let silent = ScriptedServer(handler: { message, server in
        guard let method = message["method"]?.stringValue, let id = message["id"] else { return }

        if method == "initialize" { server.reply(id, ["capabilities": [:]]) }
        if method == "$/cancelRequest" { _ = id }
    })
    let rig = Rig(servers: [silent])
    try await rig.started()
    let asking = Task { @MainActor in await rig.completion() }
    #expect(await silent.waitForMethod("textDocument/completion"))
    asking.cancel()
    #expect(await silent.waitForMethod("$/cancelRequest"))
    silent.fail(silent.messages(named: "textDocument/completion")[0]["id"]!, code: -32800, message: "cancelled")
    #expect(await asking.value == .stale(.cancelled))
}

@Test @MainActor
func completionWithoutARunningServerOrASyncedDocumentSaysWhy() async throws {
    let rig = Rig(servers: [ScriptedServer()])
    #expect(await rig.completion() == .unavailable(.notRunning))
    await rig.service.start()
    #expect(await rig.completion() == .unavailable(.documentNotSynced), "not opened")
}

@Test @MainActor
func completionNamesTheStateOfTheServerThatCannotAnswer() async throws {
    // starting: initialize is not answered yet
    let held = ScriptedServer(handler: { _, _ in })
    let starting = Rig(servers: [held])
    let start = Task { @MainActor in await starting.service.start() }
    #expect(await held.waitForMethod("initialize"))
    #expect(starting.service.state == .starting)
    #expect(await starting.completion() == .unavailable(.starting))
    held.reply(held.messages(named: "initialize")[0]["id"]!, ["capabilities": [:]])
    await start.value

    // restarting: the server died and the new one waits for its delay
    let first = ScriptedServer(), second = ScriptedServer()
    let restarting = Rig(servers: [first, second])
    try await restarting.started()
    first.die()
    #expect(await restarting.waitFor { if case .restarting = restarting.service.state { true } else { false } })
    #expect(await restarting.completion() == .unavailable(.restarting))

    // failed: given up on
    let failing = Rig(servers: [ScriptedServer(handler: { message, server in
        if let id = message["id"] { server.fail(id, code: -32603, message: "no") }
    })], delays: [.seconds(1)])
    await failing.service.start()
    #expect(await failing.waitFor { failing.clock.sleeperCount > 0 })
    failing.clock.advance(by: .seconds(1))
    #expect(await failing.waitFor { if case .failed = failing.service.state { true } else { false } })
    guard case .unavailable(.failed) = await failing.completion() else { Issue.record("expected failed"); return }
}

// MARK: Restarting

@Test @MainActor
func aServerThatDiesIsReplacedAndGivenTheDocumentsAgain() async throws {
    let first = ScriptedServer(), second = ScriptedServer()
    let rig = Rig(servers: [first, second])
    try await rig.started()
    try rig.edit(0, "// before the crash\n")
    first.die()
    #expect(await rig.waitFor { if case .restarting(1) = rig.service.state { true } else { false } })
    try rig.edit(0, "// while it is down\n")

    #expect(await rig.waitFor { rig.clock.sleeperCount > 0 })
    rig.clock.advance(by: .seconds(1))
    #expect(await second.waitForMethod("textDocument/didOpen"))
    #expect(rig.service.state == .running)
    #expect(second.methods.prefix(3) == ["initialize", "initialized", "textDocument/didOpen"])
    #expect(second.model().text("file:///w/Main.swift") == "// while it is down\n// before the crash\nlet x = 1\nx.\n")
    // And the new server is followed.
    try rig.edit(0, "!")
    #expect(await second.waitUntil { second.model().text("file:///w/Main.swift")?.hasPrefix("!// while") == true })
}

@Test @MainActor
func aCompletionOutWhenTheServerDiesIsStaleNotAnError() async throws {
    let first = ScriptedServer(handler: { message, server in
        guard let method = message["method"]?.stringValue, let id = message["id"] else { return }

        if method == "initialize" { server.reply(id, ["capabilities": [:]]) }
    })
    let rig = Rig(servers: [first, ScriptedServer()])
    try await rig.started()
    let asking = Task { @MainActor in await rig.completion() }
    #expect(await first.waitForMethod("textDocument/completion"))
    first.die()
    #expect(await asking.value == .stale(.serverRestarted))
}

@Test @MainActor
func theLastWordOfADeadServerIsNotMistakenForTheNewOnes() async throws {
    let first = ScriptedServer(), second = ScriptedServer()
    let rig = Rig(servers: [first, second])
    try await rig.started()
    first.die()
    #expect(await rig.waitFor { rig.clock.sleeperCount > 0 })
    rig.clock.advance(by: .seconds(1))
    #expect(await second.waitForMethod("textDocument/didOpen"))
    // A report that the first server sent before it died, delivered late (the hop from its reader
    // thread to the main actor can take as long as it likes).
    rig.service.received("textDocument/publishDiagnostics", [
        "uri": "file:///w/Main.swift",
        "version": 0,
        "diagnostics": [["message": "from the dead", "range": ["start": ["line": 0, "character": 0], "end": ["line": 0, "character": 1]]]],
    ], from: 1)
    #expect(rig.service.diagnostics(for: rig.session) == nil)
    // The current server is believed.
    rig.service.received("textDocument/publishDiagnostics", [
        "uri": "file:///w/Main.swift",
        "version": 0,
        "diagnostics": [["message": "from the living", "range": ["start": ["line": 0, "character": 0], "end": ["line": 0, "character": 1]]]],
    ], from: 2)
    #expect(rig.service.diagnostics(for: rig.session)?.items.first?.message == "from the living")
}

@Test @MainActor
func aServerThatKeepsFailingIsGivenUpOnAndTextEditingGoesOn() async throws {
    let rig = Rig(servers: [ScriptedServer(handler: { message, server in
        if let id = message["id"] { server.fail(id, code: -32603, message: "no") }
    })], delays: [.seconds(1)])
    await rig.service.start()
    #expect(await rig.waitFor { if case .restarting(1) = rig.service.state { true } else { false } })
    #expect(await rig.waitFor { rig.clock.sleeperCount > 0 })
    rig.clock.advance(by: .seconds(1))   // the factory has no more servers: the second start fails
    #expect(await rig.waitFor { if case .failed = rig.service.state { true } else { false } })
    #expect(rig.supply.asked == 2)
    try rig.edit(0, "still editable\n")
    #expect(rig.session.text.hasPrefix("still editable"))
}

@Test @MainActor
func stoppingShutsTheServerDownAndDoesNotRestartIt() async throws {
    let first = ScriptedServer()
    let rig = Rig(servers: [first, ScriptedServer()])
    try await rig.started()
    await rig.service.stop()
    #expect(rig.service.state == .stopped)
    #expect(first.methods.suffix(2) == ["shutdown", "exit"])
    #expect(rig.supply.asked == 1)
}

// MARK: Diagnostics

@Test @MainActor
func diagnosticsAreCurrentOnlyForTheVersionTheyWereMadeFor() async throws {
    let server = ScriptedServer()
    let rig = Rig(servers: [server])
    try await rig.started()
    server.notify("textDocument/publishDiagnostics", [
        "uri": "file:///w/Main.swift",
        "version": 0,
        "diagnostics": [["severity": 1,
                         "message": "oops",
                         "source": "sourcekitd",
                         "range": ["start": ["line": 1, "character": 0], "end": ["line": 1, "character": 1]]]],
    ])
    #expect(await rig.waitFor { rig.service.diagnostics(for: rig.session) != nil })
    var report = try #require(rig.service.diagnostics(for: rig.session))
    #expect(report.freshness == .current && report.reportedVersion == 0)
    #expect(report.items == [LanguageDiagnostic(severity: .error,
                                                message: "oops",
                                                source: "sourcekitd",
                                                start: LSPPosition(line: 1, character: 0),
                                                end: LSPPosition(line: 1, character: 1))])
    try rig.edit(0, "// newer\n")
    report = try #require(rig.service.diagnostics(for: rig.session))
    #expect(report.freshness == .stale, "for version 0; the text is version 1 now")
}

@Test @MainActor
func diagnosticsWithoutAVersionAreNeverCalledCurrent() async throws {
    let server = ScriptedServer()
    let rig = Rig(servers: [server])
    try await rig.started()
    server.notify("textDocument/publishDiagnostics", ["uri": "file:///w/Main.swift", "diagnostics": [["message": "no version", "range": ["start": ["line": 0, "character": 0], "end": ["line": 0, "character": 1]]]]])
    #expect(await rig.waitFor { rig.service.diagnostics(for: rig.session) != nil })
    #expect(rig.service.diagnostics(for: rig.session)?.freshness == .unverified)
    #expect(rig.service.diagnostics(for: rig.session)?.reportedVersion == nil)
    try rig.edit(0, "// the text moved on\n")
    #expect(rig.service.diagnostics(for: rig.session)?.freshness == .stale, "an edit after the report arrived: no longer the text it was about")
}

// MARK: A server that will not stay up

@Test @MainActor
func aServerThatStartsAndDiesAtOnceIsNotRestartedForever() async throws {
    let servers = [ScriptedServer(), ScriptedServer(), ScriptedServer(), ScriptedServer()]
    let rig = Rig(servers: servers, delays: [.seconds(1), .seconds(2)])
    await rig.service.start()
    servers[0].die()                                    // up, then gone at once
    #expect(await rig.waitFor { rig.clock.sleeperCount > 0 })
    rig.clock.advance(by: .seconds(1))                  // first wait: 1 s
    #expect(await rig.waitFor { rig.supply.asked == 2 && rig.service.state == .running })
    servers[1].die()                                    // and again at once
    #expect(await rig.waitFor { rig.clock.sleeperCount > 0 })
    rig.clock.advance(by: .seconds(1))
    try await Task.sleep(for: .milliseconds(30))
    #expect(rig.supply.asked == 2, "the second wait is 2 s, not 1")
    rig.clock.advance(by: .seconds(1))
    #expect(await rig.waitFor { rig.supply.asked == 3 && rig.service.state == .running })
    servers[2].die()                                    // a third time: the waits are used up
    #expect(await rig.waitFor { if case .failed = rig.service.state { true } else { false } })
    #expect(rig.supply.asked == 3)
}

@Test @MainActor
func aServerThatRanForAWhileGetsTheShortWaitAgain() async throws {
    let servers = [ScriptedServer(), ScriptedServer(), ScriptedServer()]
    let rig = Rig(servers: servers, delays: [.seconds(1), .seconds(2)])
    await rig.service.start()
    servers[0].die()
    #expect(await rig.waitFor { rig.clock.sleeperCount > 0 })
    rig.clock.advance(by: .seconds(1))
    #expect(await rig.waitFor { rig.supply.asked == 2 && rig.service.state == .running })
    rig.clock.advance(by: .seconds(120))                // it works for two minutes
    servers[1].die()
    #expect(await rig.waitFor { rig.clock.sleeperCount > 0 })
    rig.clock.advance(by: .seconds(1))                  // so the wait is the first one again
    #expect(await rig.waitFor { rig.supply.asked == 3 && rig.service.state == .running })
}

// MARK: A server that is not ready for the document yet

private func notReadyYet(failures: Int) -> ScriptedServer.Handler {
    let remaining = Locked(failures)

    return { message, server in
        guard let method = message["method"]?.stringValue, let id = message["id"] else { return }

        switch method {
        case "initialize":
            server.reply(id, ["capabilities": [:]])
        case "textDocument/completion":
            if remaining.withLock({ left -> Bool in if left > 0 { left -= 1; return true }; return false }) {
                server.fail(id, code: -32001, message: "No language service for 'file:///w/Main.swift' found")
            } else {
                server.reply(id, ["isIncomplete": false, "items": [completionItem("member")]])
            }
        default:
            server.reply(id, .null)
        }
    }
}

@Test @MainActor
func aServerThatIsNotReadyForTheDocumentYetIsAskedAgainRatherThanGivingUp() async throws {
    let server = ScriptedServer(handler: notReadyYet(failures: 2))
    let rig = Rig(servers: [server])
    try await rig.started()
    guard case .items(let items, _) = await rig.completion() else { Issue.record("expected items after the retries"); return }

    #expect(items.map(\.label) == ["member"])
    #expect(server.messages(named: "textDocument/completion").count == 3)
}

@Test @MainActor
func aServerThatNeverGetsReadyEndsInAnErrorNotAnEndlessWait() async throws {
    let server = ScriptedServer(handler: notReadyYet(failures: 1_000))
    let rig = Rig(servers: [server])
    try await rig.started()
    guard case .unavailable(.failed) = await rig.completion() else { Issue.record("expected unavailable"); return }

    #expect(server.messages(named: "textDocument/completion").count <= 5)
}

@Test @MainActor
func textTypedWhileWaitingToAskAgainMakesTheAnswerStaleNotWrong() async throws {
    let server = ScriptedServer(handler: notReadyYet(failures: 1))
    let rig = Rig(servers: [server])
    try await rig.started()
    let asking = Task { @MainActor in await rig.completion() }
    #expect(await server.waitForMethod("textDocument/completion"))
    try rig.edit(0, "// typed during the wait\n")
    #expect(await asking.value == .stale(.documentChanged))
}

// MARK: A document that is being given to a new server

@MainActor
private final class SecondCopyHeld {
    private var calls = 0
    private var gate: CheckedContinuation<Void, Never>?
    private(set) var isHolding = false

    /// The first copy goes through; the second (the re-opening on the new server) waits to be released.
    func capture(_ session: DocumentSession, _ policy: CapturePolicy) async throws -> DocumentCapture {
        calls += 1
        let capture = try await session.capture(policy: policy)
        if calls == 2 {
            isHolding = true
            await withCheckedContinuation { gate = $0 }
        }

        return capture
    }

    func release() { gate?.resume(); gate = nil }
}

@Test @MainActor
func aCompletionAskedWhileTheDocumentIsBeingGivenToTheServerWaitsForIt() async throws {
    let held = SecondCopyHeld()
    let sync = OrderedDocumentSync(limits: .init(), capturePolicy: .standard, capture: { try await held.capture($0, $1) })
    let server = ScriptedServer(handler: ScriptedServer.standard(completion: [completionItem("member")]))
    let rig = Rig(servers: [server], sync: sync)
    // The document is opened before the server is up; the server's arrival opens it again.
    try await rig.service.open(rig.session)
    await rig.service.start()
    while !held.isHolding { await Task.yield() }
    #expect(!rig.service.sync.isSynced(rig.session), "the re-opening is under way")

    let asking = Task { @MainActor in await rig.completion() }
    try await Task.sleep(for: .milliseconds(120))   // the request has been waiting for the document
    #expect(server.messages(named: "textDocument/completion").isEmpty, "nothing is asked of a server that has not been given the text")
    held.release()
    guard case .items(let items, _) = await asking.value else { Issue.record("expected the answer, not a refusal"); return }

    #expect(items.map(\.label) == ["member"])
}

@Test @MainActor
func aDocumentThatNeverGetsInStepIsRefusedAfterAShortWait() async throws {
    let rig = Rig(servers: [ScriptedServer()])
    await rig.service.start()   // the document was never opened
    let start = ContinuousClock.now
    #expect(await rig.completion() == .unavailable(.documentNotSynced))
    // About a second when the machine is idle (20 waits of 50 ms); the bound only says "not for ever",
    // since the suite runs next to builds and language servers.
    #expect(ContinuousClock.now - start < .seconds(40))
}

// MARK: Hover

private func range(_ line: Int, _ from: Int, _ to: Int) -> JSONValue {
    ["start": ["line": .int(line), "character": .int(from)], "end": ["line": .int(line), "character": .int(to)]]
}

@Test @MainActor
func hoverReturnsPlainTextAndTheRangeItIsAbout() async throws {
    let markdown = "```swift\nlet x: Int\n```\n\n---\nThe **value** of `x`.\n"
    let server = ScriptedServer(handler: ScriptedServer.standard(hover: ["contents": ["kind": "markdown", "value": .string(markdown)], "range": range(0, 4, 5)]))
    let rig = Rig(servers: [server])
    try await rig.started()
    rig.caret = 4
    guard case .content(let content) = await rig.hover() else { Issue.record("expected content"); return }

    #expect(content.text == "let x: Int\n\n---\nThe value of x.")
    #expect(content.range == UTF16TextRange(location: 4, length: 1))
    let params = try #require(server.messages(named: "textDocument/hover").first?["params"])
    #expect(params["position"] == ["line": 0, "character": 4])
}

@Test @MainActor
func hoverUnderstandsTheOtherShapesOfContents() async throws {
    let shapes: [(JSONValue, String)] = [
        (["contents": "plain words"], "plain words"),
        (["contents": ["language": "c", "value": "int f(void)"]], "int f(void)"),
        (["contents": [.string("first"), ["language": "c", "value": "int g()"], ["kind": "plaintext", "value": "last"]]], "first\n\nint g()\n\nlast"),
    ]
    for (answer, expected) in shapes {
        let rig = Rig(servers: [ScriptedServer(handler: ScriptedServer.standard(hover: answer))])
        try await rig.started()
        guard case .content(let content) = await rig.hover() else { Issue.record("expected content for \(answer)"); return }

        #expect(content.text == expected)
        #expect(content.range == nil)
    }
}

@Test @MainActor
func hoverWithNothingToSayIsNothing() async throws {
    for answer: JSONValue in [.null, ["contents": ""], ["contents": ["kind": "markdown", "value": "```\n```"]], ["contents": []]] {
        let rig = Rig(servers: [ScriptedServer(handler: ScriptedServer.standard(hover: answer))])
        try await rig.started()
        #expect(await rig.hover() == .nothing, "\(answer)")
    }
}

@Test @MainActor
func hoverIsAskedBehindTheEditsAlreadyMade() async throws {
    let server = ScriptedServer(handler: ScriptedServer.standard(hover: ["contents": "t"]))
    let rig = Rig(servers: [server])
    try await rig.started()
    try rig.edit(12, "abc")
    rig.caret = 14
    _ = await rig.hover()
    #expect(server.methods.suffix(2) == ["textDocument/didChange", "textDocument/hover"])
    #expect(server.messages(named: "textDocument/hover")[0]["params"]?["position"] == ["line": 1, "character": 4])
}

@Test @MainActor
func aHoverAnswerForTextOrAPlaceThatChangedIsDroppedAndMarkedTextAsksNothing() async throws {
    let silent = ScriptedServer(handler: { message, server in
        guard let method = message["method"]?.stringValue, let id = message["id"] else { return }

        if method == "initialize" { server.reply(id, ["capabilities": [:]]) }
    })
    let rig = Rig(servers: [silent])
    try await rig.started()
    let edited = Task { @MainActor in await rig.hover() }
    #expect(await silent.waitForMethod("textDocument/hover"))
    try rig.edit(0, "// typed meanwhile\n")
    silent.reply(silent.messages(named: "textDocument/hover")[0]["id"]!, ["contents": "late"])
    #expect(await edited.value == .failed(.stale(.documentChanged)))

    rig.caret = 25
    let moved = Task { @MainActor in await rig.hover() }
    #expect(await silent.waitUntil { silent.messages(named: "textDocument/hover").count == 2 })
    rig.caret = 26
    silent.reply(silent.messages(named: "textDocument/hover")[1]["id"]!, ["contents": "late"])
    #expect(await moved.value == .failed(.stale(.caretMoved)))

    rig.session.compositionDidChange(.began)
    #expect(await rig.hover() == .failed(.suppressedByComposition))
    #expect(silent.messages(named: "textDocument/hover").count == 2, "nothing was asked")
    rig.session.compositionDidChange(.ended)
}

@Test @MainActor
func hoverAndDefinitionBeforeTheServerRunsSayWhy() async throws {
    let rig = Rig(servers: [ScriptedServer()])
    #expect(await rig.hover() == .failed(.unavailable(.notRunning)))
    #expect(await rig.definition() == .failed(.unavailable(.notRunning)))
    await rig.service.start()
    #expect(await rig.hover() == .failed(.unavailable(.documentNotSynced)), "not opened")
}

// MARK: Definition

@Test @MainActor
func definitionInTheSameDocumentGivesAnOffsetAndInAnotherFileAPlace() async throws {
    let own: JSONValue = ["uri": "file:///w/Main.swift", "range": range(0, 4, 5)]
    let other: JSONValue = ["uri": "file:///w/Other.swift", "range": range(7, 2, 9)]
    let server = ScriptedServer(handler: ScriptedServer.standard(definition: [own, other]))
    let rig = Rig(servers: [server])
    try await rig.started()
    rig.caret = 12
    #expect(await rig.definition() == .locations([
        DefinitionLocation(path: "/w/Main.swift", line: 0, character: 4, offset: 4),
        DefinitionLocation(path: "/w/Other.swift", line: 7, character: 2, offset: nil),
    ]))
    #expect(server.messages(named: "textDocument/definition")[0]["params"]?["position"] == ["line": 1, "character": 2])
}

@Test @MainActor
func definitionAcceptsASingleLocationAndALocationLinkAndIgnoresWhatIsNotAFile() async throws {
    let link: JSONValue = ["targetUri": "file:///w/Link.swift", "targetRange": range(1, 0, 20), "targetSelectionRange": range(1, 5, 9)]
    let cases: [(JSONValue, DefinitionOutcome)] = [
        (["uri": "file:///w/One.swift", "range": range(2, 3, 4)], .locations([DefinitionLocation(path: "/w/One.swift", line: 2, character: 3)])),
        ([link], .locations([DefinitionLocation(path: "/w/Link.swift", line: 1, character: 5)])),
        ([["uri": "sourcekit-lsp://swift-symbol/String", "range": range(0, 0, 1)]], .nothing),
        (.null, .nothing),
        ([], .nothing),
    ]
    for (answer, expected) in cases {
        let rig = Rig(servers: [ScriptedServer(handler: ScriptedServer.standard(definition: answer))])
        try await rig.started()
        #expect(await rig.definition() == expected, "\(answer)")
    }
}

// MARK: The toolchain's server

@Test @MainActor
func theServerIsStartedFromTheSourceKitLSPOfTheToolchainItIsGiven() async throws {
    let marker = FileManager.default.temporaryDirectory.appendingPathComponent("started-\(UUID().uuidString)")
    let script = FileManager.default.temporaryDirectory.appendingPathComponent("fake-lsp-\(UUID().uuidString).sh")
    try "#!/bin/sh\ntouch '\(marker.path)'\nexec cat\n".write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    defer {
        try? FileManager.default.removeItem(at: marker)
        try? FileManager.default.removeItem(at: script)
    }
    let service = SourceKitLanguageService(workspaceRoot: FileManager.default.temporaryDirectory)
    service.toolchain = Toolchain(swift: "/x/swift", sourceKitLSP: script.path, version: "test")

    let starting = Task { await service.start() }
    let deadline = ContinuousClock.now + .seconds(60)
    while !FileManager.default.fileExists(atPath: marker.path), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    service.terminateNow()
    starting.cancel()

    #expect(FileManager.default.fileExists(atPath: marker.path), "the server of the toolchain was run, not the one `xcrun` finds")
}
