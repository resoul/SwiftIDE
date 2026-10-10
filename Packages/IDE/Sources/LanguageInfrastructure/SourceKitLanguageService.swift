import Foundation
import IDEApplication
import IDEDomain
import os
import Synchronization

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
    /// What the report was made on top of when it arrived.
    public let basis: DiagnosticsBasis
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
        didSet {
            guard state != oldValue else { return }

            onStateChange?(state)
            refreshReadiness()
        }
    }
    public var onStateChange: (@MainActor (LanguageServiceState) -> Void)?
    /// Whether the server is up, what it is busy with, whether the project's configuration may be
    /// used: kept apart, with one reason to show (TK-018, ADR-028).
    public private(set) var readiness = ProjectReadiness.make(server: .stopped, isFallbackRoot: false, progress: ProgressTracker(), trust: .undecided)
    public var onReadinessChange: (@MainActor (ProjectReadiness) -> Void)?
    /// The root holds no project: the server's own default settings are what documents get.
    public var isFallbackRoot = false {
        didSet { refreshReadiness() }
    }
    public var onDiagnostics: (@MainActor (DocumentSession) -> Void)?

    private let root: URL
    private let channelFactory: ChannelFactory
    private let restartPolicy: RestartPolicy
    private let clock: any DelayClock
    private var connection: LanguageServerConnection?
    /// Counts started servers; an exit report from an earlier one is ignored.
    private var serverNumber = 0
    private var restartTask: Task<Void, Never>?
    private var diagnostics: [String: (version: Int?, items: [LanguageDiagnostic], arrivedAtVersion: UInt64?, basis: DiagnosticsBasis)] = [:]
    private var wantsRunning = false
    /// How long a pull of diagnostics may take: a server that stays silent does not hold it forever.
    static let pullTimeout: Duration = .seconds(5)
    /// What came of the pulls, newest last (also written to the system log): why a withheld report
    /// stayed withheld.
    private(set) var diagnosticsPullLog: [String] = []
    private var pulls: [String: Pull] = [:]
    /// Counts the reports stored for each document, pushed or pulled: a pull whose answer comes
    /// after a newer report was stored must not overwrite it.
    private var diagnosticsUpdates: [String: Int] = [:]
    private static let log = Logger(subsystem: "SwiftIDE", category: "language-diagnostics")
    private var progress = ProgressTracker()
    private var trust: ConfigurationTrust = .undecided
    private var isAskingForTrust = false
    /// Where the user's decision about the project's configuration is kept. Set by whoever owns the
    /// application's settings; a service without one refuses the configuration and keeps nothing.
    public var trustStore: (any ProjectTrustStore)? {
        didSet { trust = storedTrust(); refreshReadiness() }
    }
    /// Asks the user. Without it the answer to the server's question is a refusal.
    public var trustPrompt: TrustPrompt?
    /// When the current server became ready, and how many servers in a row died before staying up.
    private var runningSince: Duration?
    private var shortLivedInARow = 0

    public init(
        workspaceRoot: URL,
        sync: OrderedDocumentSync = OrderedDocumentSync(),
        restartPolicy: RestartPolicy = RestartPolicy(),
        clock: any DelayClock = SystemDelayClock(),
        trustStore: (any ProjectTrustStore)? = nil,
        trustPrompt: TrustPrompt? = nil,
        channelFactory: @escaping ChannelFactory = SourceKitLanguageService.sourceKitLSP
    ) {
        root = workspaceRoot
        self.sync = sync
        self.restartPolicy = restartPolicy
        self.clock = clock
        self.trustStore = trustStore
        self.trustPrompt = trustPrompt
        self.channelFactory = channelFactory
        trust = storedTrust()
        refreshReadiness()
    }

    private func storedTrust() -> ConfigurationTrust {
        switch trustStore?.decision(forRoot: DocumentPath.canonical(root.path)) {
        case .granted?: .granted
        case .refused?: .refused
        case nil: .undecided
        }
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

        forgetWork()
        state = .stopped
    }

    /// Stops the server and starts a new one: the documents are opened again, and a changed trust
    /// decision is what the new server is answered with.
    public func restart() async {
        await stop()
        await start()
    }

    /// Ends the server at once, without the polite shutdown: for the moment the application quits,
    /// when there is no time to wait. The server ends when its pipes close.
    public func terminateNow() {
        wantsRunning = false
        restartTask?.cancel()
        serverNumber += 1
        connection?.close()
        connection = nil
        forgetWork()
        state = .stopped
    }

    private func launch(attempt: Int) async {
        serverNumber += 1
        let number = serverNumber
        forgetWork()
        state = attempt == 0 ? .starting : .restarting(attempt: attempt)
        do {
            let channel = try await channelFactory()
            let connection = LanguageServerConnection(
                channel: channel,
                onNotification: { [weak self] method, params in
                    Task { @MainActor in self?.received(method, params, from: number) }
                },
                onRequest: { [weak self] method, params in
                    guard let self else { return .null }

                    return await self.answerServerRequest(method, params)
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
        forgetWork()
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
        if let uri = sync.uri(of: session) {
            pulls.removeValue(forKey: uri)?.cancel(.cancelled)
            diagnostics.removeValue(forKey: uri)
            diagnosticsUpdates.removeValue(forKey: uri)
        }

        sync.close(session)
    }

    // MARK: Completion

    /// Completions at the caret. `caret` is asked again when the answer arrives: the answer is
    /// used only if the document, the caret and the server are still the ones it was asked for.
    public func completion(for session: DocumentSession, caret: @MainActor () -> Int) async -> CompletionOutcome {
        switch await positionRequest("textDocument/completion", extra: ["context": ["triggerKind": 1]], session: session, offset: caret) {
        case .failure(let failure): return CompletionOutcome(failure)
        case .success(let answer): return Self.parseCompletion(answer, session: session, sync: sync)
        }
    }

    /// A request about a place in a document, with everything that keeps its answer honest: it
    /// waits for the document to be in step with the server, goes into the outbox behind every
    /// change already made, is asked again while the server has no language service for the file
    /// yet, and is dropped if the text, the place, the server or the input method changed meanwhile.
    /// `offset` is asked again when the answer arrives.
    private func positionRequest(
        _ method: String,
        extra: [String: JSONValue],
        session: DocumentSession,
        offset place: @MainActor () -> Int
    ) async -> Result<JSONValue, LanguageRequestFailure> {
        switch state {
        case .running: break
        case .starting: return .failure(.unavailable(.starting))
        case .restarting: return .failure(.unavailable(.restarting))
        case .failed(let reason): return .failure(.unavailable(.failed(reason)))
        case .stopped: return .failure(.unavailable(.notRunning))
        }
        guard let connection else { return .failure(.unavailable(.notRunning)) }

        guard !session.isComposing else { return .failure(.suppressedByComposition) }

        let offset = place()
        let version = session.version, generation = sync.generation
        // A document is out of step with the server for a moment when it is being opened or
        // opened again (a new server has just arrived): wait for that rather than refuse.
        var waits = 0
        while !sync.isSynced(session), waits < Self.syncWaits {
            waits += 1
            try? await Task.sleep(for: .milliseconds(50))
            if Task.isCancelled { return .failure(.stale(.cancelled)) }

            if session.version != version { return .failure(.stale(.documentChanged)) }

            if place() != offset { return .failure(.stale(.caretMoved)) }

            if sync.generation != generation { return .failure(.stale(.serverRestarted)) }
        }
        guard let uri = sync.uri(of: session), let position = sync.position(of: offset, in: session) else {
            return .failure(.unavailable(.documentNotSynced))
        }

        // Put in the outbox right here, behind every change already made. A server that has only
        // just been given the document may not have a language service for it yet: that answer
        // means "not yet", and the question is asked again a little later.
        var parameters: [String: JSONValue] = ["textDocument": ["uri": .string(uri)], "position": position.json]
        for (key, value) in extra { parameters[key] = value }
        var answer: JSONValue = .null
        for attempt in 0...Self.notReadyRetries {
            let request = connection.request(method, .object(parameters))
            do {
                answer = try await request.response()
                break
            } catch is CancellationError {
                return .failure(.stale(.cancelled))
            } catch let error as LSPError {
                switch error {
                case .connectionClosed, .restarted:
                    return .failure(.stale(.serverRestarted))
                case .server(let code, _) where code == -32800 || code == -32801:
                    return .failure(.stale(.cancelled))
                case .server(let code, let message) where code == -32001 && message.contains("No language service"):
                    guard attempt < Self.notReadyRetries else { return .failure(.unavailable(.failed(String(describing: error)))) }

                    try? await Task.sleep(for: .milliseconds(150 * (attempt + 1)))
                    // What was asked for may be gone by now; then there is nothing to ask again.
                    if Task.isCancelled { return .failure(.stale(.cancelled)) }

                    if sync.generation != generation { return .failure(.stale(.serverRestarted)) }

                    if session.version != version { return .failure(.stale(.documentChanged)) }

                    if place() != offset { return .failure(.stale(.caretMoved)) }

                    continue
                default:
                    return .failure(.unavailable(.failed(String(describing: error))))
                }
            } catch {
                return .failure(.unavailable(.failed(String(describing: error))))
            }
        }

        if Task.isCancelled { return .failure(.stale(.cancelled)) }

        if sync.generation != generation { return .failure(.stale(.serverRestarted)) }

        if session.version != version { return .failure(.stale(.documentChanged)) }

        if session.isComposing { return .failure(.stale(.compositionStarted)) }

        if place() != offset { return .failure(.stale(.caretMoved)) }

        return .success(answer)
    }

    // MARK: Hover and definition

    public func hover(for session: DocumentSession, offset: @MainActor () -> Int) async -> HoverOutcome {
        switch await positionRequest("textDocument/hover", extra: [:], session: session, offset: offset) {
        case .failure(let failure): return .failed(failure)
        case .success(let answer): return Self.parseHover(answer, session: session, sync: sync)
        }
    }

    public func definition(for session: DocumentSession, offset: @MainActor () -> Int) async -> DefinitionOutcome {
        switch await positionRequest("textDocument/definition", extra: [:], session: session, offset: offset) {
        case .failure(let failure): return .failed(failure)
        case .success(let answer): return Self.parseDefinition(answer, session: session, sync: sync)
        }
    }

    static func parseHover(_ answer: JSONValue, session: DocumentSession, sync: OrderedDocumentSync) -> HoverOutcome {
        guard answer != .null, let contents = answer["contents"] else { return .nothing }

        let text = Self.plainText(ofHoverContents: contents)
        guard !text.isEmpty else { return .nothing }

        var range: UTF16TextRange?
        if let start = position(answer["range"]?["start"]), let end = position(answer["range"]?["end"]),
           let from = sync.offset(of: start, in: session), let to = sync.offset(of: end, in: session), to >= from {
            range = UTF16TextRange(location: from, length: to - from)
        }

        return .content(HoverContent(text: text, range: range))
    }

    /// `contents` is a `MarkupContent`, a `MarkedString` (a string, or a code block) or a list of them.
    static func plainText(ofHoverContents contents: JSONValue) -> String {
        if let string = contents.stringValue { return markdownToPlainText(string) }

        if let value = contents["value"]?.stringValue { return markdownToPlainText(value) }

        if let list = contents.arrayValue {
            return list.map(plainText(ofHoverContents:)).filter { !$0.isEmpty }.joined(separator: "\n\n")
        }

        return ""
    }

    /// Fences and emphasis off, the words kept: enough for a tooltip.
    static func markdownToPlainText(_ markdown: String) -> String {
        var lines: [String] = []
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") { continue }

            lines.append(String(line))
        }
        var text = lines.joined(separator: "\n")
        for mark in ["**", "__", "`"] { text = text.replacingOccurrences(of: mark, with: "") }
        // A blank line at the start or end, and more than one in a row, say nothing.
        while text.contains("\n\n\n") { text = text.replacingOccurrences(of: "\n\n\n", with: "\n\n") }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func parseDefinition(_ answer: JSONValue, session: DocumentSession, sync: OrderedDocumentSync) -> DefinitionOutcome {
        let raw: [JSONValue]
        if let list = answer.arrayValue {
            raw = list
        } else if answer != .null {
            raw = [answer]
        } else {
            raw = []
        }

        let own = sync.uri(of: session)
        let locations = raw.compactMap { item -> DefinitionLocation? in
            // A `Location` has `uri` and `range`; a `LocationLink` has `targetUri` and `targetSelectionRange`.
            let uri = item["uri"]?.stringValue ?? item["targetUri"]?.stringValue
            let range = item["range"] ?? item["targetSelectionRange"] ?? item["targetRange"]
            guard let uri, let url = URL(string: uri), url.isFileURL, let start = position(range?["start"]) else { return nil }

            let offset = uri == own ? sync.offset(of: start, in: session) : nil

            return DefinitionLocation(path: url.path, line: start.line, character: start.character, offset: offset)
        }

        return locations.isEmpty ? .nothing : .locations(locations)
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

        return DiagnosticsReport(items: stored.items, reportedVersion: stored.version, freshness: freshness, basis: stored.basis)
    }

    /// The report in the text as it is now, if the server's positions can be read against it: the
    /// document is in step with the server, and a report that names its version names this one.
    public func documentDiagnostics(for session: DocumentSession) -> DocumentDiagnostics? {
        guard let report = diagnostics(for: session), report.freshness != .stale, sync.isSynced(session) else { return nil }

        let items = report.items.compactMap { item -> DocumentDiagnostic? in
            guard let from = sync.offset(of: item.start, in: session), let to = sync.offset(of: item.end, in: session), to >= from else { return nil }

            return DocumentDiagnostic(
                range: UTF16TextRange(location: from, length: to - from),
                severity: DocumentDiagnostic.Severity(rawValue: item.severity.rawValue) ?? .error,
                message: item.message,
                source: item.source
            )
        }

        return DocumentDiagnostics(items: items, version: session.version, isVerified: report.freshness == .current, basis: report.basis)
    }

    func received(_ method: String, _ params: JSONValue, from number: Int) {
        guard number == serverNumber else { return }

        switch method {
        case "$/progress": progressReceived(params)
        case "textDocument/publishDiagnostics": diagnosticsReceived(params)
        default: break
        }
    }

    private func diagnosticsReceived(_ params: JSONValue) {
        guard let uri = params["uri"]?.stringValue else { return }

        let version = params["version"]?.intValue
        let items = Self.parseDiagnostics(params["diagnostics"])
        let session = sync.openDocuments.first(where: { sync.uri(of: $0) == uri })
        diagnostics[uri] = (version, items, session?.version, readiness.diagnosticsBasis)
        diagnosticsUpdates[uri, default: 0] += 1
        if let session { onDiagnostics?(session) }
    }

    private static func parseDiagnostics(_ list: JSONValue?) -> [LanguageDiagnostic] {
        (list?.arrayValue ?? []).compactMap { raw -> LanguageDiagnostic? in
            guard let message = raw["message"]?.stringValue,
                  let start = position(raw["range"]?["start"]), let end = position(raw["range"]?["end"]) else { return nil }

            return LanguageDiagnostic(
                severity: LanguageDiagnostic.Severity(rawValue: raw["severity"]?.intValue ?? 1) ?? .error,
                message: message,
                source: raw["source"]?.stringValue,
                start: start,
                end: end
            )
        }
    }

    /// The initial preparation has just ended. A report made while it went on is withheld, and the
    /// server may not publish another until the text changes, so a fresh one is asked for: a pull of
    /// `textDocument/diagnostic`, which the server of Xcode 27 answers although it does not advertise
    /// it (ADR-028). It is bounded (`pullTimeout`), cancelled when the document closes, and its answer
    /// is used only if nothing newer came meanwhile. If it cannot be used, the withheld report stays
    /// withheld until the next one is pushed, and the reason is recorded.
    private func pullWithheldDiagnostics() {
        guard let connection else { return }

        let number = serverNumber
        for session in sync.openDocuments {
            guard let uri = sync.uri(of: session), pulls[uri] == nil else { continue }

            if let stored = diagnostics[uri], stored.basis != .preparing { continue }

            let sentAt = session.version
            let updatesAtSend = diagnosticsUpdates[uri, default: 0]
            let request = connection.request("textDocument/diagnostic", ["textDocument": ["uri": .string(uri)]])
            let clock = clock
            Task { @MainActor [weak self] in
                let result: PullResult = await withCheckedContinuation { continuation in
                    let shot = OneShot(continuation)
                    let timer = Task {
                        try? await clock.sleep(for: SourceKitLanguageService.pullTimeout)
                        guard !Task.isCancelled else { return }

                        shot.fulfil(.timedOut)
                        request.cancel()
                    }
                    Task {
                        do {
                            shot.fulfil(.answer(try await request.response()))
                        } catch {
                            shot.fulfil(.failed(String(describing: error)))
                        }
                        timer.cancel()
                    }
                    self?.pulls[uri] = Pull(shot: shot, request: request, timer: timer)
                }
                self?.pullFinished(result, for: session, uri: uri, sentAtVersion: sentAt, updatesAtSend: updatesAtSend, from: number)
            }
        }
    }

    private func pullFinished(_ result: PullResult, for session: DocumentSession, uri: String, sentAtVersion: UInt64, updatesAtSend: Int, from number: Int) {
        pulls.removeValue(forKey: uri)
        let name = (uri as NSString).lastPathComponent
        switch result {
        case .timedOut:
            return recordPull("pull for \(name) timed out after \(Self.pullTimeout)")
        case .cancelled:
            return recordPull("pull for \(name) cancelled: the document closed")
        case .failed(let reason):
            return recordPull("pull for \(name) failed: \(reason)")
        case .answer(let answer):
            guard number == serverNumber else { return recordPull("pull for \(name) ignored: the server was replaced") }

            guard sync.uri(of: session) == uri else { return recordPull("pull for \(name) ignored: the document closed or moved to another address") }

            guard session.version == sentAtVersion else { return recordPull("pull for \(name) ignored: the text changed") }

            guard diagnosticsUpdates[uri, default: 0] == updatesAtSend else { return recordPull("pull for \(name) ignored: a newer report came") }

            guard answer["kind"]?.stringValue == "full" else { return recordPull("pull for \(name) ignored: the answer was not a full report") }

            diagnostics[uri] = (nil, Self.parseDiagnostics(answer["items"]), session.version, readiness.diagnosticsBasis)
            diagnosticsUpdates[uri, default: 0] += 1
            onDiagnostics?(session)
        }
    }

    private func recordPull(_ line: String) {
        diagnosticsPullLog.append(line)
        if diagnosticsPullLog.count > 20 { diagnosticsPullLog.removeFirst() }
        Self.log.notice("\(line, privacy: .public)")
    }

    private enum PullResult: Sendable {
        case answer(JSONValue)
        case failed(String)
        case timedOut
        case cancelled
    }

    private struct Pull {
        let shot: OneShot<PullResult>
        let request: LanguageServerConnection.Request
        let timer: Task<Void, Never>

        func cancel(_ result: PullResult) {
            shot.fulfil(result)
            timer.cancel()
            request.cancel()
        }
    }

    /// The first of an answer, the timeout and a cancellation decides; the others do nothing.
    private final class OneShot<Value: Sendable>: Sendable {
        private let continuation: Mutex<CheckedContinuation<Value, Never>?>

        init(_ continuation: CheckedContinuation<Value, Never>) {
            self.continuation = Mutex(continuation)
        }

        func fulfil(_ value: Value) {
            let taken = continuation.withLock { held -> CheckedContinuation<Value, Never>? in
                defer { held = nil }

                return held
            }
            taken?.resume(returning: value)
        }
    }

    // MARK: Readiness, progress and trust

    private func refreshReadiness() {
        let server: ServerStatus = switch state {
        case .stopped: .stopped
        case .starting: .starting
        case .running: .running
        case .restarting: .restarting
        case .failed: .failed
        }
        let updated = ProjectReadiness.make(
            server: server,
            isFallbackRoot: isFallbackRoot,
            progress: progress,
            trust: trust,
            isAskingForTrust: isAskingForTrust
        )
        guard updated != readiness else { return }

        readiness = updated
        onReadinessChange?(updated)
    }

    /// What a server that is gone was doing is not being done; a question it put is not waiting.
    private func forgetWork() {
        progress.reset()
        isAskingForTrust = false
        refreshReadiness()
    }

    private func progressReceived(_ params: JSONValue) {
        let token = params["token"]?.stringValue ?? params["token"]?.intValue.map(String.init)
        guard let token, let value = params["value"], let kind = value["kind"]?.stringValue else { return }

        let message = value["message"]?.stringValue
        let percentage = value["percentage"]?.intValue
        let wasPreparing = progress.isInitialPreparation
        switch kind {
        case "begin": progress.apply(token: token, .begin(title: value["title"]?.stringValue ?? "", message: message, percentage: percentage))
        case "report": progress.apply(token: token, .report(message: message, percentage: percentage))
        case "end": progress.apply(token: token, .end)
        default: return
        }
        refreshReadiness()
        if wasPreparing, progress.hasCompletedInitialPreparation { pullWithheldDiagnostics() }
    }

    /// The server's requests of the client. Progress registration and everything unknown get an
    /// empty answer; the question whether to trust the project's configuration is the user's.
    private func answerServerRequest(_ method: String, _ params: JSONValue) async -> JSONValue {
        guard method == "window/showMessageRequest" else { return .null }

        let titles = (params["actions"]?.arrayValue ?? []).compactMap { $0["title"]?.stringValue }
        guard let grant = titles.first(where: { $0 == "Trust Workspace" }) else { return .null }

        let refuse = titles.first(where: { $0 == "Don't Trust" })
        let decision = await decideTrust()
        switch decision {
        case .granted: return ["title": .string(grant)]
        case .refused: return refuse.map { ["title": .string($0)] } ?? .null
        }
    }

    private func decideTrust() async -> TrustDecision {
        let key = DocumentPath.canonical(root.path)
        if let kept = trustStore?.decision(forRoot: key) {
            setTrust(kept)

            return kept
        }

        // Nobody to ask (no window): the safe answer, and not recorded, since no one decided.
        guard let trustPrompt else {
            setTrust(.refused)

            return .refused
        }

        isAskingForTrust = true
        refreshReadiness()
        let decision = await trustPrompt(root.lastPathComponent, root)
        isAskingForTrust = false
        trustStore?.record(decision, forRoot: key)
        setTrust(decision)

        return decision
    }

    private func setTrust(_ decision: TrustDecision) {
        trust = decision == .granted ? .granted : .refused
        refreshReadiness()
    }
}
