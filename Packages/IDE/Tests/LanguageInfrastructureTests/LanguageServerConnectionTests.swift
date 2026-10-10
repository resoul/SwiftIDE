import Foundation
import Synchronization
import Testing
@testable import LanguageInfrastructure

/// A value several threads may touch.
final class Locked<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withLock<R>(_ body: (inout Value) -> R) -> R { lock.withLock { body(&value) } }
}

private func makeConnection(_ server: ScriptedServer, notifications: Locked<[String]>? = nil, closed: Locked<Int>? = nil) -> LanguageServerConnection {
    LanguageServerConnection(
        channel: server,
        onNotification: { method, _ in notifications?.withLock { $0.append(method) } },
        onClose: { closed?.withLock { $0 += 1 } }
    )
}

@Test
func messagesArriveInTheOrderTheyWerePutInTheOutboxEvenWhenTheServerIsSlow() async throws {
    let server = ScriptedServer()
    server.slowDown(every: 3, by: .milliseconds(4))
    let connection = makeConnection(server)
    var expected: [String] = []
    for i in 0..<120 {
        if i % 4 == 3 {
            _ = connection.request("test/request\(i)", [:])
            expected.append("test/request\(i)")
        } else {
            connection.notify("test/notify\(i)", ["n": .int(i)])
            expected.append("test/notify\(i)")
        }
    }
    #expect(await server.waitUntil { server.methods.count == 120 })
    #expect(server.methods == expected)
    connection.close()
}

@Test
func answersFindTheirRequestsWhateverOrderTheyComeIn() async throws {
    let server = ScriptedServer(handler: nil)
    let connection = makeConnection(server)
    let first = connection.request("a", [:])
    let second = connection.request("b", [:])
    let third = connection.request("c", [:])
    #expect(await server.waitUntil { server.received.count == 3 })
    let ids = server.received.compactMap { $0["id"] }
    server.reply(ids[2], "third")
    server.reply(ids[0], "first")
    server.reply(ids[1], "second")
    #expect(try await first.response() == "first")
    #expect(try await second.response() == "second")
    #expect(try await third.response() == "third")
    connection.close()
}

@Test
func anAnswerThatArrivedBeforeItWasAwaitedIsNotLost() async throws {
    let server = ScriptedServer()
    let connection = makeConnection(server)
    let request = connection.request("early", [:])
    #expect(await server.waitUntil { server.methods.contains("early") })
    try await Task.sleep(for: .milliseconds(50))
    #expect(try await request.response() == .null)
    connection.close()
}

@Test
func anErrorAnswerIsThrownWithItsCodeAndMessage() async throws {
    let server = ScriptedServer(handler: { message, server in
        if let id = message["id"] { server.fail(id, code: -32601, message: "no such method") }
    })
    let connection = makeConnection(server)
    let request = connection.request("nothing", [:])
    await #expect(throws: LSPError.server(code: -32601, message: "no such method")) { _ = try await request.response() }
    connection.close()
}

@Test
func messagesDeliveredInPiecesAndInHeapsAreAllRead() async throws {
    let server = ScriptedServer(handler: nil)
    let notifications = Locked<[String]>([])
    let connection = makeConnection(server, notifications: notifications)
    server.send(["jsonrpc": "2.0", "method": "one", "params": ["text": "αβγ😀"]], inPiecesOf: 1)
    server.send(["jsonrpc": "2.0", "method": "two", "params": [:]], inPiecesOf: 7)
    server.send(["jsonrpc": "2.0", "method": "three", "params": [:]])
    #expect(await server.waitUntil { notifications.withLock { $0.count } == 3 })
    #expect(notifications.withLock { $0 } == ["one", "two", "three"])
    connection.close()
}

@Test
func aRequestFromTheServerIsAnsweredSoThatItCanGoOn() async throws {
    let server = ScriptedServer(handler: nil)
    let connection = makeConnection(server)
    server.send(["jsonrpc": "2.0", "id": 77, "method": "window/workDoneProgress/create", "params": [:]])
    #expect(await server.waitUntil { server.received.contains { $0["id"] == 77 && $0["result"] != nil } })
    connection.close()
}

@Test
func whenTheServerEndsEveryRequestStillOutFails() async throws {
    let server = ScriptedServer(handler: nil)
    let closed = Locked(0)
    let connection = makeConnection(server, closed: closed)
    let request = connection.request("slow", [:])
    #expect(await server.waitUntil { server.methods == ["slow"] })
    server.die()
    await #expect(throws: LSPError.connectionClosed) { _ = try await request.response() }
    #expect(await server.waitUntil { closed.withLock { $0 } == 1 })
    #expect(connection.isClosed)
    // Nothing more is accepted, and asking is not a crash.
    #expect(connection.notify("late", [:]) == false)
    await #expect(throws: LSPError.connectionClosed) { _ = try await connection.request("late", [:]).response() }
    #expect(closed.withLock { $0 } == 1, "reported once")
}

@Test
func cancellingTheAwaitingTaskTellsTheServer() async throws {
    let server = ScriptedServer(handler: nil)
    let connection = makeConnection(server)
    let request = connection.request("long", [:])
    let waiting = Task { try await request.response() }
    #expect(await server.waitUntil { server.methods == ["long"] })
    waiting.cancel()
    #expect(await server.waitForMethod("$/cancelRequest"))
    #expect(server.messages(named: "$/cancelRequest").first?["params"]?["id"] == .int(request.id))
    server.fail(.int(request.id), code: -32800, message: "cancelled")
    await #expect(throws: LSPError.server(code: -32800, message: "cancelled")) { _ = try await waiting.value }
    connection.close()
}

@Test @MainActor
func aDeferredNotificationIsBuiltWhenItsTurnComes() async throws {
    let server = ScriptedServer(handler: nil)
    server.hold()
    let connection = makeConnection(server)
    var value = 1
    connection.notify("before", [:])
    connection.notifyLater { ("later", ["value": .int(value)]) }
    connection.notify("after", [:])
    // The outbox is behind a server that does not read; the value changes meanwhile.
    try await Task.sleep(for: .milliseconds(20))
    value = 2
    server.release()
    #expect(await server.waitUntil { server.methods.count == 3 })
    #expect(server.methods == ["before", "later", "after"])
    #expect(server.messages(named: "later").first?["params"]?["value"] == .int(2), "built at the time of writing")
    connection.close()
}
