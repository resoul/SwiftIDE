import Foundation
import Synchronization

/// One JSON-RPC connection to a language server, with a single ordered way out.
///
/// Everything sent goes through one outbox in the order it was put there, and it is put there
/// synchronously: calling `notify` and then `request` from the main actor means the server reads
/// the notification first. That is the whole point. A `Task` per message, or a call to an actor
/// per message, would not promise it: two tasks started in order may run in either.
public final class LanguageServerConnection: Sendable {
    public typealias NotificationHandler = @Sendable (_ method: String, _ params: JSONValue) -> Void
    /// Answers a request the server makes of the client (progress registration, a question for the
    /// user, configuration). It may take as long as it needs: nothing else waits for it.
    public typealias RequestHandler = @Sendable (_ method: String, _ params: JSONValue) async -> JSONValue

    private enum Outbound {
        /// Encoded when it is written, by the writer, not by whoever put it in the outbox: a
        /// document sent whole can be megabytes of text, and that is not the main thread's to encode.
        case message(JSONValue)
        /// Built when its turn comes, from whatever is true then: a resynchronisation must carry
        /// the text of the moment it is sent, not of the moment it was asked for.
        case deferred(@Sendable @MainActor () -> (method: String, params: JSONValue)?)
    }

    private struct State {
        var nextID = 1
        var outbox: [Outbound] = []
        var pending: [Int: ResponseSlot] = [:]
        var closed = false
        var sent = 0
    }

    private let channel: any LSPChannel
    private let state = Mutex(State())
    private let wake: AsyncStream<Void>.Continuation
    private let onNotification: NotificationHandler
    private let onRequest: RequestHandler
    private let onClose: @Sendable () -> Void
    private let tasks = Mutex<[Task<Void, Never>]>([])

    public init(
        channel: any LSPChannel,
        onNotification: @escaping NotificationHandler,
        onRequest: @escaping RequestHandler = { _, _ in .null },
        onClose: @escaping @Sendable () -> Void = {}
    ) {
        self.channel = channel
        self.onNotification = onNotification
        self.onRequest = onRequest
        self.onClose = onClose
        let (wakeStream, wake) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.wake = wake
        let writer = Task.detached { [weak self] in
            for await _ in wakeStream {
                guard let self else { return }

                await self.drain()
            }
        }
        let reader = Task.detached { [weak self] in
            var framing = LSPFraming.Reader()
            let incoming = channel.incoming
            do {
                for await chunk in incoming {
                    framing.append(chunk)
                    while let body = try framing.next() {
                        self?.receive(body)
                    }
                }
            } catch {
                // A header that makes no sense: the stream cannot be followed any more.
            }
            self?.finish()
        }
        tasks.withLock { $0 = [writer, reader] }
    }

    // MARK: Sending, in order

    /// Messages put in the outbox and not yet written. A caller that sees this grow knows the
    /// server is not keeping up.
    public var pendingOutbound: Int { state.withLock { $0.outbox.count } }

    /// How many messages have been written.
    public var sentCount: Int { state.withLock { $0.sent } }

    public var isClosed: Bool { state.withLock { $0.closed } }

    @discardableResult
    public func notify(_ method: String, _ params: JSONValue) -> Bool {
        enqueue(.message(["jsonrpc": "2.0", "method": .string(method), "params": params]))
    }

    /// A notification whose content is decided when it is about to be written, on the main actor.
    /// Returning nil sends nothing.
    @discardableResult
    public func notifyLater(_ make: @escaping @Sendable @MainActor () -> (method: String, params: JSONValue)?) -> Bool {
        enqueue(.deferred(make))
    }

    /// Puts a request in the outbox, after everything already there, and returns at once. The
    /// answer is awaited on the returned handle.
    public func request(_ method: String, _ params: JSONValue) -> Request {
        let slot = ResponseSlot()
        let id: Int? = state.withLock { state in
            guard !state.closed else { return nil }

            let id = state.nextID
            state.nextID += 1
            state.pending[id] = slot
            state.outbox.append(.message(["jsonrpc": "2.0", "id": .int(id), "method": .string(method), "params": params]))

            return id
        }
        guard let id else {
            slot.fulfil(.failure(LSPError.connectionClosed))

            return Request(id: 0, slot: slot, connection: self)
        }

        wake.yield()

        return Request(id: id, slot: slot, connection: self)
    }

    public final class Request: Sendable {
        public let id: Int
        fileprivate let slot: ResponseSlot
        private let connection: LanguageServerConnection

        fileprivate init(id: Int, slot: ResponseSlot, connection: LanguageServerConnection) {
            self.id = id
            self.slot = slot
            self.connection = connection
        }

        /// The server's answer. If the awaiting task is cancelled, the server is told to stop
        /// working on it; the answer that comes back (an error, or the result if it was too late)
        /// is still delivered.
        public func response() async throws -> JSONValue {
            try await withTaskCancellationHandler {
                try await slot.value()
            } onCancel: {
                cancel()
            }
        }

        public func cancel() {
            guard id != 0 else { return }

            connection.notify("$/cancelRequest", ["id": .int(id)])
        }
    }

    private func enqueue(_ item: Outbound) -> Bool {
        let accepted = state.withLock { state -> Bool in
            guard !state.closed else { return false }

            state.outbox.append(item)

            return true
        }
        if accepted { wake.yield() }

        return accepted
    }

    private func drain() async {
        while true {
            let next: Outbound? = state.withLock { state in
                state.outbox.isEmpty ? nil : state.outbox.removeFirst()
            }
            guard let next else { return }

            let data: Data?
            switch next {
            case .message(let message):
                data = Self.encode(message)
            case .deferred(let make):
                if let made = await MainActor.run(body: { make() }) {
                    data = Self.encode(["jsonrpc": "2.0", "method": .string(made.method), "params": made.params])
                } else {
                    data = nil
                }
            }
            guard let data else { continue }

            do {
                try await channel.write(LSPFraming.frame(data))
                state.withLock { $0.sent += 1 }
            } catch {
                finish()

                return
            }
        }
    }

    // MARK: Receiving

    private func receive(_ body: Data) {
        guard let message = try? JSONDecoder().decode(JSONValue.self, from: body) else { return }

        let id = message["id"]
        let method = message["method"]?.stringValue
        switch (method, id) {
        case (let method?, let id?):
            // A request from the server (progress registration, a question, configuration). The
            // handler answers in its own time, so one that waits for the user holds nothing up.
            let params = message["params"] ?? .null
            let handler = onRequest
            let task = Task { [weak self] in
                let result = await handler(method, params)
                _ = self?.enqueue(.message(["jsonrpc": "2.0", "id": id, "result": result]))
            }
            tasks.withLock { $0.append(task) }
        case (let method?, nil):
            onNotification(method, message["params"] ?? .null)
        case (nil, let id?):
            guard let number = id.intValue else { return }

            let slot = state.withLock { $0.pending.removeValue(forKey: number) }
            if let error = message["error"] {
                slot?.fulfil(.failure(LSPError.server(code: error["code"]?.intValue ?? 0, message: error["message"]?.stringValue ?? "")))
            } else {
                slot?.fulfil(.success(message["result"] ?? .null))
            }
        case (nil, nil):
            break
        }
    }

    private func finish() {
        let (pending, alreadyClosed) = state.withLock { state -> ([ResponseSlot], Bool) in
            let was = state.closed
            state.closed = true
            state.outbox.removeAll()
            let slots = Array(state.pending.values)
            state.pending.removeAll()

            return (slots, was)
        }
        for slot in pending { slot.fulfil(.failure(LSPError.connectionClosed)) }
        wake.finish()
        if !alreadyClosed { onClose() }
    }

    /// Ends the connection. Requests still out fail with `connectionClosed`.
    public func close() {
        channel.close()
        finish()
        for task in tasks.withLock({ $0 }) { task.cancel() }
    }

    private static func encode(_ message: JSONValue) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]

        return (try? encoder.encode(message)) ?? Data()
    }
}

/// The place an answer is put when it arrives, readable before or after.
final class ResponseSlot: Sendable {
    private struct State {
        var result: Result<JSONValue, any Error>?
        var waiter: CheckedContinuation<JSONValue, any Error>?
    }

    private let state = Mutex(State())

    func fulfil(_ result: Result<JSONValue, any Error>) {
        let waiter: CheckedContinuation<JSONValue, any Error>? = state.withLock { state in
            guard state.result == nil else { return nil }

            state.result = result
            defer { state.waiter = nil }

            return state.waiter
        }
        waiter?.resume(with: result)
    }

    func value() async throws -> JSONValue {
        try await withCheckedThrowingContinuation { continuation in
            let ready: Result<JSONValue, any Error>? = state.withLock { state in
                if let result = state.result { return result }
                state.waiter = continuation

                return nil
            }
            if let ready { continuation.resume(with: ready) }
        }
    }
}
