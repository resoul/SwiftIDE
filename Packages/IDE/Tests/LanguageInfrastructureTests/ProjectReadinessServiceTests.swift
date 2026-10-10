import Foundation
import IDEApplication
import IDEDomain
import IDETestSupport
import Testing
@testable import LanguageInfrastructure

private final class Servers: @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [ScriptedServer]
    private(set) var made: [ScriptedServer] = []

    init(_ servers: [ScriptedServer]) { queue = servers }

    func next() throws -> ScriptedServer {
        try lock.withLock {
            guard !queue.isEmpty else { throw LSPError.notRunning }

            let server = queue.removeFirst()
            made.append(server)

            return server
        }
    }
}

/// How many times the user was asked, and what the answer is to be.
@MainActor
private final class Asked {
    private(set) var count = 0
    private(set) var roots: [URL] = []
    var answer: TrustDecision = .refused
    /// When set, the question waits until `release()`.
    var holds = false
    private var continuation: CheckedContinuation<Void, Never>?

    func prompt(_ name: String, _ root: URL) async -> TrustDecision {
        count += 1
        roots.append(root)
        if holds { await withCheckedContinuation { continuation = $0 } }

        return answer
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class Rig {
    let servers: Servers
    let clock = ManualDelayClock()
    let service: SourceKitLanguageService
    let store = MemoryProjectTrustStore()
    let asked = Asked()
    let session: DocumentSession
    let root = URL(fileURLWithPath: "/w")

    init(servers list: [ScriptedServer] = [ScriptedServer()], prompt: Bool = true, fallback: Bool = false) {
        servers = Servers(list)
        let servers = servers
        let asked = asked
        var promptClosure: TrustPrompt?
        if prompt { promptClosure = { name, root in await asked.prompt(name, root) } }
        service = SourceKitLanguageService(
            workspaceRoot: root,
            restartPolicy: .init(delays: [.seconds(1), .seconds(2)]),
            clock: clock,
            trustStore: store,
            trustPrompt: promptClosure,
            channelFactory: { try servers.next() }
        )
        service.isFallbackRoot = fallback
        session = DocumentSession(path: "/w/Main.swift", backend: StringDocumentBackend(loadedText: "let x = 1\n"))
    }

    func started() async throws {
        await service.start()
        try await service.open(session)
        #expect(await servers.made[0].waitForMethod("textDocument/didOpen"))
    }

    func waitFor(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }

        return condition()
    }
}

private func progress(_ server: ScriptedServer, _ token: String, _ value: JSONValue) {
    server.notify("$/progress", ["token": .string(token), "value": value])
}

private func begin(_ server: ScriptedServer, _ token: String, _ title: String, message: String? = nil) {
    var value: [String: JSONValue] = ["kind": "begin", "title": .string(title)]
    if let message { value["message"] = .string(message) }
    progress(server, token, .object(value))
}

private func trustQuestion(_ server: ScriptedServer, id: Int) {
    server.send([
        "jsonrpc": "2.0",
        "id": .int(id),
        "method": "window/showMessageRequest",
        "params": [
            "message": "Do you trust the authors of the files in \"w\"? SourceKit-LSP found workspace-scoped configuration (.sourcekit-lsp/ or .bsp/) that may launch external processes or alter how subprocesses are sandboxed.",
            "actions": [["title": "Trust Workspace"], ["title": "Don't Trust"]],
            "type": 2,
        ],
    ])
}

private func answer(_ server: ScriptedServer, to id: Int) -> JSONValue? {
    server.received.first(where: { $0["method"] == nil && $0["id"] == .int(id) })?["result"]
}

private func publishDiagnostic(_ server: ScriptedServer, message: String = "No such module 'Lib'") {
    server.notify("textDocument/publishDiagnostics", [
        "uri": "file:///w/Main.swift",
        "diagnostics": [["severity": 1,
                         "message": .string(message),
                         "range": ["start": ["line": 0, "character": 0], "end": ["line": 0, "character": 3]]]],
    ])
}

// MARK: Progress

@Test @MainActor
func progressFromTheServerShowsAsWorkInTheReadiness() async throws {
    let server = ScriptedServer()
    let rig = Rig(servers: [server])
    try await rig.started()
    #expect(rig.service.readiness.reason == nil && rig.service.readiness.settings == .unknown, "no event proves anything")

    begin(server, "indexing.A", "Indexing", message: "0 / 3")
    #expect(await rig.waitFor { rig.service.readiness.reason == "Preparing package · 0 / 3" })
    progress(server, "indexing.A", ["kind": "report", "message": "2 / 3"])
    #expect(await rig.waitFor { rig.service.readiness.reason == "Preparing package · 2 / 3" })
    progress(server, "indexing.A", ["kind": "end"])
    #expect(await rig.waitFor { rig.service.readiness.reason == nil }, "the end of the work is not announced as readiness")
}

@Test @MainActor
func twoOperationsAtOnceAreBothKept() async throws {
    let server = ScriptedServer()
    let rig = Rig(servers: [server])
    try await rig.started()
    begin(server, "indexing.A", "Indexing", message: "1 / 4")
    begin(server, "package-reloading.B", "SourceKit-LSP: Reloading Package")
    #expect(await rig.waitFor { rig.service.readiness.operations.count == 2 })
    #expect(rig.service.readiness.settings == .loading)
    progress(server, "package-reloading.B", ["kind": "end"])
    #expect(await rig.waitFor { rig.service.readiness.operations.map(\.token) == ["indexing.A"] })
    #expect(rig.service.readiness.settings == .unknown)
}

@Test @MainActor
func theServerAnswersTheRequestThatRegistersAProgressToken() async throws {
    let server = ScriptedServer()
    let rig = Rig(servers: [server])
    try await rig.started()
    server.send(["jsonrpc": "2.0", "id": 41, "method": "window/workDoneProgress/create", "params": ["token": "indexing.A"]])
    #expect(await server.waitUntil { answer(server, to: 41) != nil })
    #expect(answer(server, to: 41) == .null)
}

@Test @MainActor
func aServerThatDiesInTheMiddleOfPreparingLeavesNoWorkBehind() async throws {
    let first = ScriptedServer(), second = ScriptedServer()
    let rig = Rig(servers: [first, second])
    try await rig.started()
    begin(first, "indexing.A", "Indexing", message: "1 / 4")
    #expect(await rig.waitFor { rig.service.readiness.reason == "Preparing package · 1 / 4" })

    first.die()
    #expect(await rig.waitFor { rig.service.readiness.server == .restarting })
    #expect(rig.service.readiness.operations.isEmpty, "what the dead server was doing is not being done")
    #expect(rig.service.readiness.reason == "Language server restarting")

    #expect(await rig.waitFor { rig.clock.sleeperCount > 0 })
    rig.clock.advance(by: .seconds(1))
    #expect(await rig.waitFor { rig.service.readiness.server == .running })
    #expect(rig.service.readiness.operations.isEmpty && rig.service.readiness.reason == nil)
    // The new server prepares afresh: a report of the old one's token means nothing to it.
    progress(second, "indexing.A", ["kind": "report", "message": "3 / 4"])
    try await Task.sleep(for: .milliseconds(50))
    #expect(rig.service.readiness.operations.isEmpty)
}

@Test @MainActor
func theReadinessChangeIsAnnouncedOnlyWhenSomethingChanged() async throws {
    let server = ScriptedServer()
    let rig = Rig(servers: [server])
    var seen: [String?] = []
    rig.service.onReadinessChange = { seen.append($0.reason) }
    try await rig.started()
    seen.removeAll()
    begin(server, "indexing.A", "Indexing", message: "1 / 4")
    #expect(await rig.waitFor { seen.contains("Preparing package · 1 / 4") })
    progress(server, "indexing.A", ["kind": "report", "message": "1 / 4"])
    try await Task.sleep(for: .milliseconds(50))
    #expect(seen == ["Preparing package · 1 / 4"], "an identical report says nothing new: \(seen)")
}

// MARK: Diagnostics basis

@Test @MainActor
func aReportThatArrivesDuringTheInitialPreparationIsMarkedAndStaysMarked() async throws {
    let server = ScriptedServer()
    let rig = Rig(servers: [server])
    try await rig.started()
    begin(server, "indexing.A", "Indexing", message: "0 / 3")
    #expect(await rig.waitFor { rig.service.readiness.isInitialPreparation })
    publishDiagnostic(server)
    #expect(await rig.waitFor { rig.service.documentDiagnostics(for: rig.session) != nil })
    #expect(rig.service.documentDiagnostics(for: rig.session)?.basis == .preparing)

    progress(server, "indexing.A", ["kind": "end"])
    #expect(await rig.waitFor { !rig.service.readiness.isInitialPreparation })
    #expect(rig.service.documentDiagnostics(for: rig.session)?.basis == .preparing, "finishing the preparation does not make the stored report reliable")

    publishDiagnostic(server, message: "a later report")
    #expect(await rig.waitFor { rig.service.documentDiagnostics(for: rig.session)?.items.first?.message == "a later report" })
    #expect(rig.service.documentDiagnostics(for: rig.session)?.basis == .unconfirmed)
}

@Test @MainActor
func aReportWithNoProgressAtAllIsUnconfirmedNotPreparing() async throws {
    let server = ScriptedServer()
    let rig = Rig(servers: [server])
    try await rig.started()
    publishDiagnostic(server)
    #expect(await rig.waitFor { rig.service.documentDiagnostics(for: rig.session) != nil })
    #expect(rig.service.documentDiagnostics(for: rig.session)?.basis == .unconfirmed)
}

@Test @MainActor
func aServerOfARootWithNoProjectIsOnFallbackSettings() async throws {
    let server = ScriptedServer()
    let rig = Rig(servers: [server], fallback: true)
    try await rig.started()
    #expect(rig.service.readiness.settings == .fallback && rig.service.readiness.reason == "Using fallback settings")
    publishDiagnostic(server, message: "'api.h' file not found")
    #expect(await rig.waitFor { rig.service.documentDiagnostics(for: rig.session) != nil })
    #expect(rig.service.documentDiagnostics(for: rig.session)?.basis == .fallback)
}

// MARK: Trust

@Test @MainActor
func theUserIsAskedAndTheAnswerIsPassedToTheServerAndKept() async throws {
    let server = ScriptedServer()
    let rig = Rig(servers: [server])
    rig.asked.answer = .granted
    try await rig.started()
    trustQuestion(server, id: 50)
    #expect(await server.waitUntil { answer(server, to: 50) != nil })

    #expect(answer(server, to: 50) == ["title": "Trust Workspace"])
    #expect(rig.asked.count == 1 && rig.asked.roots == [rig.root])
    #expect(rig.store.decision(forRoot: DocumentPath.canonical("/w")) == .granted, "kept under the canonical root")
    #expect(rig.service.readiness.trust == .granted && rig.service.readiness.reason == nil)
}

@Test @MainActor
func aRefusalIsPassedAsDontTrustAndIsSaidInTheReadiness() async throws {
    let server = ScriptedServer()
    let rig = Rig(servers: [server])
    rig.asked.answer = .refused
    try await rig.started()
    trustQuestion(server, id: 51)
    #expect(await server.waitUntil { answer(server, to: 51) != nil })

    #expect(answer(server, to: 51) == ["title": "Don't Trust"])
    #expect(rig.service.readiness.trust == .refused && rig.service.readiness.reason == "Project configuration disabled")
    #expect(rig.store.decision(forRoot: DocumentPath.canonical("/w")) == .refused)
}

@Test @MainActor
func whileTheUserDecidesTheReadinessSaysSoAndNothingElseWaits() async throws {
    let server = ScriptedServer()
    let rig = Rig(servers: [server])
    rig.asked.holds = true
    try await rig.started()
    trustQuestion(server, id: 52)
    #expect(await rig.waitFor { rig.service.readiness.isAskingForTrust })
    #expect(rig.service.readiness.reason == "Waiting for your decision on the project configuration")
    #expect(answer(server, to: 52) == nil, "not answered before the user has")

    begin(server, "indexing.A", "Indexing")
    #expect(await rig.waitFor { rig.service.readiness.operations.count == 1 }, "progress is still read while the question is open")

    rig.asked.answer = .granted
    rig.asked.release()
    #expect(await server.waitUntil { answer(server, to: 52) != nil })
    #expect(!rig.service.readiness.isAskingForTrust && rig.service.readiness.trust == .granted)
}

@Test @MainActor
func aKeptDecisionIsUsedWithoutAskingAndAfterARestartToo() async throws {
    let first = ScriptedServer(), second = ScriptedServer()
    let rig = Rig(servers: [first, second])
    rig.store.record(.granted, forRoot: DocumentPath.canonical("/w"))
    try await rig.started()
    trustQuestion(first, id: 53)
    #expect(await first.waitUntil { answer(first, to: 53) != nil })
    #expect(answer(first, to: 53) == ["title": "Trust Workspace"] && rig.asked.count == 0)

    first.die()
    #expect(await rig.waitFor { rig.clock.sleeperCount > 0 })
    rig.clock.advance(by: .seconds(1))
    #expect(await rig.waitFor { rig.service.readiness.server == .running && rig.servers.made.count == 2 })
    trustQuestion(second, id: 54)
    #expect(await second.waitUntil { answer(second, to: 54) != nil })
    #expect(answer(second, to: 54) == ["title": "Trust Workspace"] && rig.asked.count == 0, "a restart raises no new dialog")
}

@Test @MainActor
func withNoOneToAskTheConfigurationIsRefusedAndNothingIsKept() async throws {
    let server = ScriptedServer()
    let rig = Rig(servers: [server], prompt: false)
    try await rig.started()
    trustQuestion(server, id: 55)
    #expect(await server.waitUntil { answer(server, to: 55) != nil })
    #expect(answer(server, to: 55) == ["title": "Don't Trust"])
    #expect(rig.store.decision(forRoot: DocumentPath.canonical("/w")) == nil, "no one decided, so nothing is recorded")
}

@Test @MainActor
func aQuestionThatIsNotTheTrustQuestionIsAnsweredWithNull() async throws {
    let server = ScriptedServer()
    let rig = Rig(servers: [server])
    try await rig.started()
    server.send(["jsonrpc": "2.0",
                 "id": 56,
                 "method": "window/showMessageRequest",
                 "params": ["message": "Something else", "actions": [["title": "OK"]], "type": 3]])
    #expect(await server.waitUntil { answer(server, to: 56) != nil })
    #expect(answer(server, to: 56) == .null)
    #expect(rig.asked.count == 0)
}

@Test @MainActor
func changingTheDecisionAndRestartingMakesTheNewServerGetTheNewAnswer() async throws {
    let first = ScriptedServer(), second = ScriptedServer()
    let rig = Rig(servers: [first, second])
    rig.asked.answer = .refused
    try await rig.started()
    trustQuestion(first, id: 57)
    #expect(await first.waitUntil { answer(first, to: 57) != nil })

    rig.store.record(.granted, forRoot: DocumentPath.canonical("/w"))
    await rig.service.restart()
    #expect(await rig.waitFor { rig.servers.made.count == 2 })
    trustQuestion(second, id: 58)
    #expect(await second.waitUntil { answer(second, to: 58) != nil })
    #expect(answer(second, to: 58) == ["title": "Trust Workspace"])
    #expect(rig.service.readiness.trust == .granted)
}

// MARK: A fresh report after the initial preparation

/// A server that answers a pull request for diagnostics as the real one does, and says what it was asked.
private func pulling(_ answerWith: @escaping @Sendable (JSONValue) -> JSONValue?) -> ScriptedServer {
    ScriptedServer(handler: { message, server in
        guard let method = message["method"]?.stringValue, let id = message["id"] else { return }

        switch method {
        case "initialize": server.reply(id, ["capabilities": [:]])
        case "textDocument/diagnostic":
            if let result = answerWith(message) { server.reply(id, result) } else { server.fail(id, code: -32601, message: "no such method") }
        default: server.reply(id, .null)
        }
    })
}

private let pulledReport: JSONValue = [
    "kind": "full",
    "items": [["severity": 1,
               "message": "after the preparation",
               "range": ["start": ["line": 0, "character": 0], "end": ["line": 0, "character": 3]]]],
]

@Test @MainActor
func whenTheInitialPreparationEndsAFreshReportIsAskedForAndIsNotMarkedAsMadeDuringIt() async throws {
    let server = pulling { _ in pulledReport }
    let rig = Rig(servers: [server])
    try await rig.started()
    begin(server, "indexing.A", "Indexing", message: "0 / 3")
    #expect(await rig.waitFor { rig.service.readiness.isInitialPreparation })
    publishDiagnostic(server)
    #expect(await rig.waitFor { rig.service.documentDiagnostics(for: rig.session) != nil })
    #expect(rig.service.documentDiagnostics(for: rig.session)?.basis == .preparing)
    #expect(server.messages(named: "textDocument/diagnostic").isEmpty, "nothing is asked for while the preparation goes on")

    progress(server, "indexing.A", ["kind": "end"])
    #expect(await server.waitForMethod("textDocument/diagnostic"))
    #expect(await rig.waitFor { rig.service.documentDiagnostics(for: rig.session)?.items.first?.message == "after the preparation" })
    #expect(rig.service.documentDiagnostics(for: rig.session)?.basis == .unconfirmed)
    #expect(server.messages(named: "textDocument/diagnostic").first?["params"]?["textDocument"]?["uri"]?.stringValue == "file:///w/Main.swift")
}

@Test @MainActor
func aServerThatCannotAnswerAPullLeavesTheWithheldReportWithheld() async throws {
    let server = pulling { _ in nil }
    let rig = Rig(servers: [server])
    try await rig.started()
    begin(server, "indexing.A", "Indexing")
    #expect(await rig.waitFor { rig.service.readiness.isInitialPreparation })
    publishDiagnostic(server)
    #expect(await rig.waitFor { rig.service.documentDiagnostics(for: rig.session) != nil })
    progress(server, "indexing.A", ["kind": "end"])
    #expect(await server.waitForMethod("textDocument/diagnostic"))
    try await Task.sleep(for: .milliseconds(100))

    #expect(rig.service.documentDiagnostics(for: rig.session)?.basis == .preparing, "the old report does not turn reliable by itself")
}

@Test @MainActor
func aPulledReportForTextThatHasChangedSinceIsDropped() async throws {
    // This server does not answer the pull at once: the test answers by hand, after an edit.
    let slow = ScriptedServer(handler: { message, server in
        guard let method = message["method"]?.stringValue, let id = message["id"] else { return }

        switch method {
        case "initialize": server.reply(id, ["capabilities": [:]])
        case "textDocument/diagnostic": break
        default: server.reply(id, .null)
        }
    })
    let rig = Rig(servers: [slow])
    try await rig.started()
    begin(slow, "indexing.A", "Indexing")
    #expect(await rig.waitFor { rig.service.readiness.isInitialPreparation })
    publishDiagnostic(slow)
    #expect(await rig.waitFor { rig.service.documentDiagnostics(for: rig.session) != nil })
    progress(slow, "indexing.A", ["kind": "end"])
    #expect(await slow.waitForMethod("textDocument/diagnostic"))

    try rig.session.apply([DocumentEdit(range: UTF16TextRange(location: 0, length: 0), replacement: "// edited\n")], expectedVersion: rig.session.version)
    let id = try #require(slow.messages(named: "textDocument/diagnostic").first?["id"])
    slow.reply(id, pulledReport)
    try await Task.sleep(for: .milliseconds(100))
    #expect(rig.service.documentDiagnostics(for: rig.session)?.items.first?.message != "after the preparation")
}

@Test @MainActor
func nothingIsAskedForWhenNoPreparationWasSeenToEnd() async throws {
    let server = pulling { _ in pulledReport }
    let rig = Rig(servers: [server])
    try await rig.started()
    progress(server, "other.A", ["kind": "begin", "title": "Something"])
    progress(server, "other.A", ["kind": "end"])
    try await Task.sleep(for: .milliseconds(100))
    #expect(server.messages(named: "textDocument/diagnostic").isEmpty)
}

@Test @MainActor
func aReportThatAlreadyCameAfterThePreparationIsNotAskedForAgain() async throws {
    let server = pulling { _ in pulledReport }
    let rig = Rig(servers: [server])
    try await rig.started()
    begin(server, "indexing.A", "Indexing")
    #expect(await rig.waitFor { rig.service.readiness.isInitialPreparation })
    progress(server, "indexing.A", ["kind": "end"])
    #expect(await rig.waitFor { !rig.service.readiness.isInitialPreparation })
    publishDiagnostic(server, message: "a push after the preparation")
    #expect(await rig.waitFor { rig.service.documentDiagnostics(for: rig.session)?.items.first?.message == "a push after the preparation" })
    begin(server, "indexing.B", "Indexing")
    progress(server, "indexing.B", ["kind": "end"])
    try await Task.sleep(for: .milliseconds(100))
    #expect(rig.service.documentDiagnostics(for: rig.session)?.items.first?.message == "a push after the preparation")
}

@Test @MainActor
func aDocumentWhoseReportWasNotWithheldIsNotPulledWhenThePreparationEnds() async throws {
    let server = pulling { _ in pulledReport }
    let rig = Rig(servers: [server])
    try await rig.started()
    publishDiagnostic(server, message: "pushed before any progress")
    #expect(await rig.waitFor { rig.service.documentDiagnostics(for: rig.session) != nil })
    begin(server, "indexing.A", "Indexing")
    progress(server, "indexing.A", ["kind": "end"])
    #expect(await rig.waitFor { rig.service.readiness.operations.isEmpty && !rig.service.readiness.isInitialPreparation })
    try await Task.sleep(for: .milliseconds(100))

    #expect(server.messages(named: "textDocument/diagnostic").isEmpty, "only what was withheld is asked for again")
    #expect(rig.service.documentDiagnostics(for: rig.session)?.items.first?.message == "pushed before any progress")
}

// MARK: The pull is bounded and cannot overwrite what is newer

/// A server that never answers the pull by itself: the test answers, or not.
private func silentOnPull() -> ScriptedServer {
    ScriptedServer(handler: { message, server in
        guard let method = message["method"]?.stringValue, let id = message["id"] else { return }

        switch method {
        case "initialize": server.reply(id, ["capabilities": [:]])
        case "textDocument/diagnostic": break
        default: server.reply(id, .null)
        }
    })
}

/// A pull asked for after a withheld report; returns the id of that request.
@MainActor
private func pullAskedFor(_ server: ScriptedServer, _ rig: Rig) async throws -> JSONValue {
    begin(server, "indexing.A", "Indexing")
    #expect(await rig.waitFor { rig.service.readiness.isInitialPreparation })
    publishDiagnostic(server)
    #expect(await rig.waitFor { rig.service.documentDiagnostics(for: rig.session) != nil })
    progress(server, "indexing.A", ["kind": "end"])
    #expect(await server.waitForMethod("textDocument/diagnostic"))

    return try #require(server.messages(named: "textDocument/diagnostic").first?["id"])
}

@Test @MainActor
func aPushThatCameAfterThePullWasSentIsNotOverwrittenByItsLateAnswer() async throws {
    let server = silentOnPull()
    let rig = Rig(servers: [server])
    try await rig.started()
    let id = try await pullAskedFor(server, rig)

    publishDiagnostic(server, message: "a newer push")
    #expect(await rig.waitFor { rig.service.documentDiagnostics(for: rig.session)?.items.first?.message == "a newer push" })
    server.reply(id, pulledReport)
    try await Task.sleep(for: .milliseconds(100))

    #expect(rig.service.documentDiagnostics(for: rig.session)?.items.first?.message == "a newer push", "the old answer does not replace it")
    #expect(rig.service.diagnosticsPullLog.contains { $0.contains("newer report") }, "\(rig.service.diagnosticsPullLog)")
}

@Test @MainActor
func aPullThatIsNotAnsweredInFiveSecondsIsGivenUpAndCancelled() async throws {
    let server = silentOnPull()
    let rig = Rig(servers: [server])
    try await rig.started()
    let id = try await pullAskedFor(server, rig)
    #expect(await rig.waitFor { rig.clock.sleeperCount > 0 })

    rig.clock.advance(by: .seconds(4))
    #expect(server.messages(named: "$/cancelRequest").isEmpty, "not before five seconds")
    rig.clock.advance(by: .seconds(1))
    #expect(await server.waitForMethod("$/cancelRequest"))
    #expect(server.messages(named: "$/cancelRequest").first?["params"]?["id"] == id)
    #expect(await rig.waitFor { rig.service.diagnosticsPullLog.contains { $0.contains("timed out") } })

    server.reply(id, pulledReport)
    try await Task.sleep(for: .milliseconds(100))
    #expect(rig.service.documentDiagnostics(for: rig.session)?.basis == .preparing, "the withheld report stays withheld")
}

@Test @MainActor
func aPullAnsweredInTimeLeavesNoTimerBehind() async throws {
    let server = silentOnPull()
    let rig = Rig(servers: [server])
    try await rig.started()
    let id = try await pullAskedFor(server, rig)
    #expect(await rig.waitFor { rig.clock.sleeperCount > 0 })

    server.reply(id, pulledReport)
    #expect(await rig.waitFor { rig.service.documentDiagnostics(for: rig.session)?.basis == .unconfirmed })
    #expect(await rig.waitFor { rig.clock.sleeperCount == 0 }, "the timeout is cancelled once the answer is in")
    #expect(server.messages(named: "$/cancelRequest").isEmpty)
}

@Test @MainActor
func closingTheDocumentCancelsThePullAndItsLateAnswerIsIgnored() async throws {
    let server = silentOnPull()
    let rig = Rig(servers: [server])
    try await rig.started()
    let id = try await pullAskedFor(server, rig)

    rig.service.close(rig.session)
    #expect(await server.waitForMethod("$/cancelRequest"))
    #expect(await rig.waitFor { rig.service.diagnosticsPullLog.contains { $0.contains("closed") } })
    server.reply(id, pulledReport)
    try await Task.sleep(for: .milliseconds(100))
    #expect(rig.service.documentDiagnostics(for: rig.session) == nil, "nothing is stored for a closed document")
}

@Test @MainActor
func aFailedPullIsRecordedWithItsReason() async throws {
    let server = pulling { _ in nil }
    let rig = Rig(servers: [server])
    try await rig.started()
    begin(server, "indexing.A", "Indexing")
    #expect(await rig.waitFor { rig.service.readiness.isInitialPreparation })
    publishDiagnostic(server)
    #expect(await rig.waitFor { rig.service.documentDiagnostics(for: rig.session) != nil })
    progress(server, "indexing.A", ["kind": "end"])

    #expect(await rig.waitFor { rig.service.diagnosticsPullLog.contains { $0.contains("failed") && $0.contains("no such method") } }, "\(rig.service.diagnosticsPullLog)")
}

@Test @MainActor
func aPullAnsweredAfterTheDocumentMovedToAnotherAddressIsNotUsed() async throws {
    let server = silentOnPull()
    let rig = Rig(servers: [server])
    try await rig.started()
    let files = MemoryDocumentFileStore(contents: ["/w/Old.swift": "let x = 1\n"])
    let registry = DocumentRegistry()
    let open = OpenDocumentUseCase(store: files, registry: registry) { file in
        DocumentSession(loaded: file, backend: StringDocumentBackend(loadedText: file.text))
    }
    let moving = try await open.execute(path: "/w/Old.swift").session
    try await rig.service.open(moving)
    var arrivals = 0
    rig.service.onDiagnostics = { _ in arrivals += 1 }

    begin(server, "indexing.A", "Indexing")
    #expect(await rig.waitFor { rig.service.readiness.isInitialPreparation })
    server.notify("textDocument/publishDiagnostics", ["uri": "file:///w/Old.swift", "diagnostics": []])
    #expect(await rig.waitFor { arrivals > 0 })
    progress(server, "indexing.A", ["kind": "end"])
    #expect(await server.waitUntil { server.messages(named: "textDocument/diagnostic").count == 2 })
    let oldPull = try #require(server.messages(named: "textDocument/diagnostic").first { $0["params"]?["textDocument"]?["uri"]?.stringValue == "file:///w/Old.swift" }?["id"])

    _ = try await SaveDocumentUseCase(store: files).saveAs(document: moving, to: "/w/New.swift", target: .newFile, registry: registry)
    #expect(await server.waitUntil { server.messages(named: "textDocument/didOpen").contains { $0["params"]?["textDocument"]?["uri"]?.stringValue == "file:///w/New.swift" } })
    let before = arrivals
    server.reply(oldPull, pulledReport)
    #expect(await rig.waitFor { rig.service.diagnosticsPullLog.contains { $0.contains("Old.swift") && $0.contains("moved to another address") } }, "\(rig.service.diagnosticsPullLog)")
    #expect(arrivals == before, "the answer about the old address is not taken for a report of the document")
}
