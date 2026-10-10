import Foundation
import IDEApplication
import IDEDomain

public struct LanguageDiagnostic: Equatable, Sendable {
    public enum Severity: Int, Sendable { case error = 1, warning, information, hint }

    public let severity: Severity
    public let message: String
    public let source: String?
    public let start: LSPPosition
    public let end: LSPPosition
}

/// What the server said about a document, and whether it can be shown against the text on screen.
public struct DiagnosticsReport: Equatable, Sendable {
    public enum Freshness: Equatable, Sendable {
        /// For the version the document has now.
        case current
        /// For an older version: the text has changed since, positions may point elsewhere.
        case stale
        /// The server did not say which version, so there is no proof it is current; but the text
        /// has not changed since the report arrived. (SourceKit-LSP of Xcode 27 sends no version.)
        case unverified
    }

    public let items: [LanguageDiagnostic]
    public let reportedVersion: Int?
    public let freshness: Freshness
}

public enum LanguageServiceState: Equatable, Sendable {
    case stopped
    case starting
    case running
    /// The server went away; a new one is started after the wait. `attempt` counts from 1.
    case restarting(attempt: Int)
    /// Given up after the attempts allowed; text editing goes on without a language server.
    case failed(String)
}

/// SourceKit-LSP behind the editor: starts it, keeps documents in step with it (in order), asks it
/// for completions and refuses answers that no longer fit the text (ADR-020).
@MainActor
public final class SourceKitLanguageService: CompletionProviding {
    public typealias ChannelFactory = @Sendable () async throws -> any LSPChannel

    public struct RestartPolicy: Sendable {
        /// The waits before successive restarts of a server that keeps dying. When they are used up
        /// the service gives up (`failed`).
        public var delays: [Duration]
        /// A server that was up this long before it died starts the waits over.
        public var stableAfter: Duration

        public init(
            delays: [Duration] = [.milliseconds(500), .seconds(1), .seconds(2), .seconds(4), .seconds(8)],
            stableAfter: Duration = .seconds(60)
        ) {
            self.delays = delays
            self.stableAfter = stableAfter
        }
    }

    /// How many more times a completion is asked when the server says it has no language service
    /// for the document yet. It is ready within a second of starting.
    static let notReadyRetries = 4
    /// How many times 50 ms a completion waits for the document to be in step with the server.
    static let syncWaits = 20

    public let sync: OrderedDocumentSync
    public private(set) var state: LanguageServiceState = .stopped {
        didSet { if state != oldValue { onStateChange?(state) } }
    }
    public var onStateChange: (@MainActor (LanguageServiceState) -> Void)?
    public var onDiagnostics: (@MainActor (DocumentSession) -> Void)?

    private let root: URL
    private let channelFactory: ChannelFactory
    private let restartPolicy: RestartPolicy
    private let clock: any DelayClock
    private var connection: LanguageServerConnection?
    /// Counts started servers; an exit report from an earlier one is ignored.
    private var serverNumber = 0
    private var restartTask: Task<Void, Never>?
    private var diagnostics: [String: (version: Int?, items: [LanguageDiagnostic], arrivedAtVersion: UInt64?)] = [:]
    private var wantsRunning = false
    /// When the current server became ready, and how many servers in a row died before staying up.
    private var runningSince: Duration?
    private var shortLivedInARow = 0

    public init(
        workspaceRoot: URL,
        sync: OrderedDocumentSync = OrderedDocumentSync(),
        restartPolicy: RestartPolicy = RestartPolicy(),
        clock: any DelayClock = SystemDelayClock(),
        channelFactory: @escaping ChannelFactory = SourceKitLanguageService.sourceKitLSP
    ) {
        root = workspaceRoot
        self.sync = sync
        self.restartPolicy = restartPolicy
        self.clock = clock
        self.channelFactory = channelFactory
    }

    /// The `sourcekit-lsp` of the selected Xcode.
    public nonisolated static let sourceKitLSP: ChannelFactory = {
        let finder = Process()
        finder.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        finder.arguments = ["--find", "sourcekit-lsp"]
        let pipe = Pipe()
        finder.standardOutput = pipe
        finder.standardError = FileHandle.nullDevice
        try finder.run()
        finder.waitUntilExit()
        let path = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard finder.terminationStatus == 0, !path.isEmpty else { throw LSPError.notRunning }

        return try ProcessChannel(executable: URL(fileURLWithPath: path))
    }

    // MARK: Starting and restarting

    public func start() async {
        wantsRunning = true
        shortLivedInARow = 0
        restartTask?.cancel()
        await launch(attempt: 0)
    }

    public func stop() async {
        wantsRunning = false
        restartTask?.cancel()
        restartTask = nil
        serverNumber += 1
        let old = connection
        connection = nil
        sync.attach(nil)
        if let old {
            _ = old.request("shutdown", .null)
            old.notify("exit", .null)
            try? await Task.sleep(for: .milliseconds(100))
            old.close()
        }

        state = .stopped
    }

    /// Ends the server at once, without the polite shutdown: for the moment the application quits,
    /// when there is no time to wait. The server ends when its pipes close.
    public func terminateNow() {
        wantsRunning = false
        restartTask?.cancel()
        serverNumber += 1
        connection?.close()
        connection = nil
        state = .stopped
    }

    private func launch(attempt: Int) async {
        serverNumber += 1
        let number = serverNumber
        state = attempt == 0 ? .starting : .restarting(attempt: attempt)
        do {
            let channel = try await channelFactory()
            let connection = LanguageServerConnection(
                channel: channel,
                onNotification: { [weak self] method, params in
                    Task { @MainActor in self?.received(method, params, from: number) }
                },
                onClose: { [weak self] in
                    Task { @MainActor in self?.serverEnded(number) }
                }
            )
            self.connection = connection
            let initialize = connection.request("initialize", Self.initializeParams(root: root))
            _ = try await initialize.response()
            guard serverNumber == number else { return connection.close() }

            connection.notify("initialized", [:])
            state = .running
            runningSince = clock.now
            // Only now is the server spoken to about documents: each is opened again, from its
            // current text, behind the "initialized" notification.
            sync.attach(connection)
        } catch {
            guard serverNumber == number else { return }

            connection?.close()
            connection = nil
            scheduleRestart(after: attempt, reason: String(describing: error))
        }
    }

    private func serverEnded(_ number: Int) {
        guard number == serverNumber, wantsRunning else { return }

        connection = nil
        sync.attach(nil)
        // One that stayed up begins the waits again; one that died soon after starting goes on from
        // where the last one left off, so a server that cannot stay up is not restarted forever.
        if let since = runningSince, clock.now - since >= restartPolicy.stableAfter {
            shortLivedInARow = 1   // this death is the first of a new run of them
        } else {
            shortLivedInARow += 1
        }

        runningSince = nil
        scheduleRestart(after: shortLivedInARow - 1, reason: "the language server ended")
    }

    private func scheduleRestart(after attempt: Int, reason: String) {
        guard wantsRunning else { return }

        guard attempt < restartPolicy.delays.count else {
            state = .failed(reason)

            return
        }

        state = .restarting(attempt: attempt + 1)
        let delay = restartPolicy.delays[attempt]
        restartTask?.cancel()
        restartTask = Task { [weak self, clock] in
            try? await clock.sleep(for: delay)
            guard !Task.isCancelled else { return }

            await self?.launch(attempt: attempt + 1)
        }
    }

    private static func initializeParams(root: URL) -> JSONValue {
        [
            "processId": .int(Int(ProcessInfo.processInfo.processIdentifier)),
            "rootUri": .string(root.absoluteString),
            "workspaceFolders": [["uri": .string(root.absoluteString), "name": .string(root.lastPathComponent)]],
            "capabilities": [
                "general": ["positionEncodings": ["utf-16"]],
                "textDocument": [
                    "synchronization": ["didSave": false, "willSave": false],
                    "publishDiagnostics": ["versionSupport": true],
                    "completion": ["completionItem": ["snippetSupport": false]],
                ],
                "window": ["workDoneProgress": true],
            ],
        ]
    }

    // MARK: Documents

    public func open(_ session: DocumentSession) async throws {
        try await sync.open(session)
    }

    public func close(_ session: DocumentSession) {
        sync.close(session)
        if let uri = sync.uri(of: session) { diagnostics.removeValue(forKey: uri) }
    }

    // MARK: Completion

    /// Completions at the caret. `caret` is asked again when the answer arrives: the answer is
    /// used only if the document, the caret and the server are still the ones it was asked for.
    public func completion(for session: DocumentSession, caret: @MainActor () -> Int) async -> CompletionOutcome {
        switch state {
        case .running: break
        case .starting: return .unavailable(.starting)
        case .restarting: return .unavailable(.restarting)
        case .failed(let reason): return .unavailable(.failed(reason))
        case .stopped: return .unavailable(.notRunning)
        }
        guard let connection else { return .unavailable(.notRunning) }

        guard !session.isComposing else { return .suppressedByComposition }

        let offset = caret()
        let version = session.version, generation = sync.generation
        // A document is out of step with the server for a moment when it is being opened or
        // opened again (a new server has just arrived): wait for that rather than refuse.
        var waits = 0
        while !sync.isSynced(session), waits < Self.syncWaits {
            waits += 1
            try? await Task.sleep(for: .milliseconds(50))
            if Task.isCancelled { return .stale(.cancelled) }
            if session.version != version { return .stale(.documentChanged) }
            if caret() != offset { return .stale(.caretMoved) }
            if sync.generation != generation { return .stale(.serverRestarted) }
        }
        guard let uri = sync.uri(of: session), let position = sync.position(of: offset, in: session) else {
            return .unavailable(.documentNotSynced)
        }

        // Put in the outbox right here, behind every change already made. A server that has only
        // just been given the document may not have a language service for it yet: that answer
        // means "not yet", and the question is asked again a little later.
        var answer: JSONValue = .null
        for attempt in 0...Self.notReadyRetries {
            let request = connection.request("textDocument/completion", [
                "textDocument": ["uri": .string(uri)],
                "position": position.json,
                "context": ["triggerKind": 1],
            ])
            do {
                answer = try await request.response()
                break
            } catch is CancellationError {
                return .stale(.cancelled)
            } catch let error as LSPError {
                switch error {
                case .connectionClosed, .restarted:
                    return .stale(.serverRestarted)
                case .server(let code, _) where code == -32800 || code == -32801:
                    return .stale(.cancelled)
                case .server(let code, let message) where code == -32001 && message.contains("No language service"):
                    guard attempt < Self.notReadyRetries else { return .unavailable(.failed(String(describing: error))) }

                    try? await Task.sleep(for: .milliseconds(150 * (attempt + 1)))
                    // What was asked for may be gone by now; then there is nothing to ask again.
                    if Task.isCancelled { return .stale(.cancelled) }
                    if sync.generation != generation { return .stale(.serverRestarted) }
                    if session.version != version { return .stale(.documentChanged) }
                    if caret() != offset { return .stale(.caretMoved) }
                    continue
                default:
                    return .unavailable(.failed(String(describing: error)))
                }
            } catch {
                return .unavailable(.failed(String(describing: error)))
            }
        }

        if Task.isCancelled { return .stale(.cancelled) }
        if sync.generation != generation { return .stale(.serverRestarted) }
        if session.version != version { return .stale(.documentChanged) }
        if session.isComposing { return .stale(.compositionStarted) }
        if caret() != offset { return .stale(.caretMoved) }

        return Self.parseCompletion(answer, session: session, sync: sync)
    }

    private static func parseCompletion(_ answer: JSONValue, session: DocumentSession, sync: OrderedDocumentSync) -> CompletionOutcome {
        let list: [JSONValue]
        var incomplete = false
        if let items = answer.arrayValue {
            list = items
        } else if let items = answer["items"]?.arrayValue {
            list = items
            incomplete = answer["isIncomplete"] == .bool(true)
        } else {
            list = []
        }

        let items = list.compactMap { item -> CompletionItem? in
            guard let raw = item["label"]?.stringValue else { return nil }

            // clangd puts a marker in front of labels, a space or a bullet (for results from its index
            // rather than from the file); it is not text.
            let label = String(raw.drop(while: { $0 == " " || $0 == "\u{2022}" }))
            guard !label.isEmpty else { return nil }

            var range: UTF16TextRange?
            if let edit = item["textEdit"], let r = edit["range"] ?? edit["replace"],
               let start = position(r["start"]), let end = position(r["end"]),
               let from = sync.offset(of: start, in: session), let to = sync.offset(of: end, in: session), to >= from {
                range = UTF16TextRange(location: from, length: to - from)
            }

            return CompletionItem(
                label: label,
                detail: item["detail"]?.stringValue,
                insertText: item["textEdit"]?["newText"]?.stringValue ?? item["insertText"]?.stringValue ?? label,
                sortText: item["sortText"]?.stringValue,
                filterText: item["filterText"]?.stringValue,
                replacementRange: range,
                kind: kind(item["kind"]?.intValue)
            )
        }

        return .items(items, isIncomplete: incomplete)
    }

    /// The protocol's `CompletionItemKind` numbers, folded into the few the editor tells apart.
    private static func kind(_ number: Int?) -> CompletionKind {
        switch number {
        case 2: .method
        case 3: .function
        case 4: .initializer
        case 5, 10: .property
        case 6: .variable
        case 7, 8, 13, 22, 25: .type
        case 9: .module
        case 14: .keyword
        case 12, 20, 21: .constant
        default: .other
        }
    }

    private static func position(_ value: JSONValue?) -> LSPPosition? {
        guard let line = value?["line"]?.intValue, let character = value?["character"]?.intValue else { return nil }

        return LSPPosition(line: line, character: character)
    }

    // MARK: Diagnostics

    public func diagnostics(for session: DocumentSession) -> DiagnosticsReport? {
        guard let uri = sync.uri(of: session), let stored = diagnostics[uri] else { return nil }

        let freshness: DiagnosticsReport.Freshness
        if let version = stored.version {
            freshness = version == Int(session.version) ? .current : .stale
        } else {
            // Not invented: the report names no version. Only what is known for certain is used,
            // that the text did or did not change after the report arrived.
            freshness = stored.arrivedAtVersion == session.version ? .unverified : .stale
        }

        return DiagnosticsReport(items: stored.items, reportedVersion: stored.version, freshness: freshness)
    }

    func received(_ method: String, _ params: JSONValue, from number: Int) {
        guard number == serverNumber, method == "textDocument/publishDiagnostics",
              let uri = params["uri"]?.stringValue else { return }

        let version = params["version"]?.intValue
        let items = (params["diagnostics"]?.arrayValue ?? []).compactMap { raw -> LanguageDiagnostic? in
            guard let message = raw["message"]?.stringValue,
                  let start = Self.position(raw["range"]?["start"]), let end = Self.position(raw["range"]?["end"]) else { return nil }

            return LanguageDiagnostic(
                severity: LanguageDiagnostic.Severity(rawValue: raw["severity"]?.intValue ?? 1) ?? .error,
                message: message,
                source: raw["source"]?.stringValue,
                start: start,
                end: end
            )
        }
        let session = sync.openDocuments.first(where: { sync.uri(of: $0) == uri })
        diagnostics[uri] = (version, items, session?.version)
        if let session { onDiagnostics?(session) }
    }
}
