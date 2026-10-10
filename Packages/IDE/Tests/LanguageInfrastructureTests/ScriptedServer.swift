import Foundation
import LanguageInfrastructure

/// The other end of a connection, played by the test: it records what is written to it, in order,
/// can answer, can be slow, and can die.
final class ScriptedServer: LSPChannel, @unchecked Sendable {
    typealias Handler = @Sendable (JSONValue, ScriptedServer) -> Void

    let incoming: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private let lock = NSLock()
    private var framing = Framing()
    private var messages: [JSONValue] = []
    private var held = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var delayEvery: (Int, Duration)?
    private var writes = 0
    var handler: Handler?

    init(handler: Handler? = ScriptedServer.standard()) {
        let (stream, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
        incoming = stream
        self.continuation = continuation
        self.handler = handler
    }

    /// Initialises, shuts down and answers everything else with null; completion with `items`.
    static func standard(completion: [JSONValue] = []) -> Handler {
        { message, server in
            guard let method = message["method"]?.stringValue, let id = message["id"] else { return }

            switch method {
            case "initialize": server.reply(id, ["capabilities": [:]])
            case "textDocument/completion": server.reply(id, ["isIncomplete": false, "items": .array(completion)])
            default: server.reply(id, .null)
            }
        }
    }

    // MARK: Being written to

    func write(_ data: Data) async throws {
        let (shouldHold, pause) = lock.withLock { () -> (Bool, Duration?) in
            writes += 1
            var pause: Duration?
            if let (every, duration) = delayEvery, writes % every == 0 { pause = duration }

            return (held, pause)
        }
        if shouldHold { await withCheckedContinuation { c in lock.withLock { waiting.append(c) } } }
        if let pause { try? await Task.sleep(for: pause) }
        let bodies: [Data] = lock.withLock {
            framing.append(data)
            var out: [Data] = []
            while let body = framing.next() { out.append(body) }

            return out
        }
        for body in bodies {
            guard let message = try? JSONDecoder().decode(JSONValue.self, from: body) else { continue }

            lock.withLock { messages.append(message) }
            handler?(message, self)
        }
    }

    func close() { continuation.finish() }

    /// Writes wait until `release()`: a server that is busy.
    func hold() { lock.withLock { held = true } }

    func release() {
        let continuations = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            held = false
            defer { waiting.removeAll() }

            return waiting
        }
        for continuation in continuations { continuation.resume() }
    }

    /// Every n-th write takes a while, so that ordering is tested against a writer that varies.
    func slowDown(every n: Int, by duration: Duration) { lock.withLock { delayEvery = (n, duration) } }

    // MARK: Reading what was written

    var received: [JSONValue] { lock.withLock { messages } }
    var methods: [String] { received.compactMap { $0["method"]?.stringValue } }

    /// What a server would believe about its documents after everything written to it so far.
    func model() -> LSPDocumentModel {
        var model = LSPDocumentModel()
        for message in received { model.consume(message) }

        return model
    }

    func messages(named method: String) -> [JSONValue] {
        received.filter { $0["method"]?.stringValue == method }
    }

    func waitUntil(timeout: Duration = .seconds(10), _ condition: @Sendable () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }

        return condition()
    }

    func waitForMethod(_ method: String, count: Int = 1) async -> Bool {
        await waitUntil { self.methods.filter { $0 == method }.count >= count }
    }

    // MARK: Speaking

    func reply(_ id: JSONValue, _ result: JSONValue) {
        send(["jsonrpc": "2.0", "id": id, "result": result])
    }

    func fail(_ id: JSONValue, code: Int, message: String) {
        send(["jsonrpc": "2.0", "id": id, "error": ["code": .int(code), "message": .string(message)]])
    }

    func notify(_ method: String, _ params: JSONValue) {
        send(["jsonrpc": "2.0", "method": .string(method), "params": params])
    }

    func send(_ message: JSONValue, inPiecesOf size: Int? = nil) {
        let body = try! JSONEncoder().encode(message)
        var data = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
        data.append(body)
        guard let size else { continuation.yield(data); return }

        var start = data.startIndex
        while start < data.endIndex {
            let end = data.index(start, offsetBy: size, limitedBy: data.endIndex) ?? data.endIndex
            continuation.yield(data[start..<end])
            start = end
        }
    }

    func die() { continuation.finish() }

    private struct Framing {
        var buffer = Data()
        mutating func append(_ data: Data) { buffer.append(data) }
        mutating func next() -> Data? {
            guard let range = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }

            let header = String(decoding: buffer[buffer.startIndex..<range.lowerBound], as: UTF8.self)
            guard let length = header.split(separator: ":").last.flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }) else { return nil }

            guard buffer.distance(from: range.upperBound, to: buffer.endIndex) >= length else { return nil }

            let end = buffer.index(range.upperBound, offsetBy: length)
            let body = Data(buffer[range.upperBound..<end])
            buffer.removeSubrange(buffer.startIndex..<end)

            return body
        }
    }
}

/// What a language server would believe about its documents after reading the messages: the
/// protocol's `didOpen` and `didChange` applied literally, with positions read as the protocol
/// defines them. If this equals the editor's text, the server has been told the truth.
struct LSPDocumentModel {
    private(set) var texts: [String: [UInt16]] = [:]
    private(set) var versions: [String: Int] = [:]
    private(set) var problems: [String] = []

    mutating func consume(_ message: JSONValue) {
        guard let method = message["method"]?.stringValue, let params = message["params"] else { return }

        let uri = params["textDocument"]?["uri"]?.stringValue ?? ""
        switch method {
        case "textDocument/didOpen":
            texts[uri] = Array((params["textDocument"]?["text"]?.stringValue ?? "").utf16)
            versions[uri] = params["textDocument"]?["version"]?.intValue
        case "textDocument/didClose":
            texts.removeValue(forKey: uri)
            versions.removeValue(forKey: uri)
        case "textDocument/didChange":
            guard var units = texts[uri] else { return problems.append("change for unopened \(uri)") }

            for change in params["contentChanges"]?.arrayValue ?? [] {
                let text = Array((change["text"]?.stringValue ?? "").utf16)
                if let range = change["range"] {
                    guard let start = offset(range["start"], in: units), let end = offset(range["end"], in: units), start <= end else {
                        problems.append("bad range \(range)")
                        continue
                    }

                    units.replaceSubrange(start..<end, with: text)
                } else {
                    units = text
                }
            }
            texts[uri] = units
            if let version = params["textDocument"]?["version"]?.intValue {
                if let previous = versions[uri], version <= previous { problems.append("version \(version) after \(previous)") }
                versions[uri] = version
            }
        default:
            break
        }
    }

    func text(_ uri: String) -> String? {
        texts[uri].map { String(decoding: $0, as: UTF16.self) }
    }

    private func offset(_ position: JSONValue?, in units: [UInt16]) -> Int? {
        guard let line = position?["line"]?.intValue, let character = position?["character"]?.intValue else { return nil }

        var starts = [0]
        var i = 0
        while i < units.count {
            if units[i] == 0x0A { starts.append(i + 1) }
            else if units[i] == 0x0D {
                if i + 1 < units.count, units[i + 1] == 0x0A { i += 1 }
                starts.append(i + 1)
            }

            i += 1
        }
        guard line < starts.count else { return nil }

        let start = starts[line]
        let lineEnd = line + 1 < starts.count ? starts[line + 1] : units.count
        var content = lineEnd - start
        while content > 0, units[start + content - 1] == 0x0A || units[start + content - 1] == 0x0D { content -= 1 }

        return start + min(character, content)
    }
}
