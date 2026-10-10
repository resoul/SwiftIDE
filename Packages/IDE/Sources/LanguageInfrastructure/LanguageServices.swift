import Foundation
import IDEApplication
import IDEDomain

/// The language servers of the running application: one for each SwiftPM package that has an open
/// document, and one for everything else (documents with no file yet, files outside any package),
/// which the server handles one file at a time (ADR-022).
///
/// A server is started when its first document is given and stopped when its last one is closed;
/// the one for loose files stays up. A document that is saved under another name moves to the
/// server of its new place.
@MainActor
public final class LanguageServices: CompletionProviding, HoverProviding, DefinitionProviding, DiagnosticsProviding {
    public typealias MakeService = @MainActor (_ root: URL, _ virtualDirectory: URL) -> SourceKitLanguageService

    private struct Managed {
        let session: DocumentSession
        let languageSubscription: UUID
    }

    private struct Home {
        let root: URL
        let service: SourceKitLanguageService
        let saveSubscription: UUID
    }

    /// The folder that stands for "no package". It stays empty.
    public let scratchRoot: URL
    private let makeService: MakeService
    private let languages: DocumentLanguages
    /// The languages this kind of server serves.
    /// SourceKit-LSP serves Swift itself and hands the C family to its clangd (TK-017).
    private let servedLanguages: Set<DocumentLanguage> = [.swift, .c, .cpp, .objectiveC, .objectiveCPP]
    private var services: [URL: SourceKitLanguageService] = [:]
    private var homes: [DocumentID: Home] = [:]
    private var managed: [DocumentID: Managed] = [:]
    private var latestDiagnostics: [DocumentID: DocumentDiagnostics] = [:]
    private var diagnosticsObservers: [UUID: (document: DocumentID, observer: @MainActor () -> Void)] = [:]
    private var readinessObservers: [UUID: (document: DocumentID, observer: @MainActor () -> Void)] = [:]
    /// The folders the user opened and the project each file belongs to.
    public let contexts: ProjectContexts
    private var contextsSubscription: UUID?
    /// Where the user's decisions about projects' configuration are kept (the application's settings).
    public var trustStore: (any ProjectTrustStore)?
    /// Asks the user whether a project's configuration may be used.
    public var trustPrompt: TrustPrompt?

    public init(
        scratchRoot: URL,
        languages: DocumentLanguages = DocumentLanguages(),
        contexts: ProjectContexts = ProjectContexts(),
        trustStore: (any ProjectTrustStore)? = nil,
        makeService: @escaping MakeService = { root, virtual in
            SourceKitLanguageService(workspaceRoot: root, sync: OrderedDocumentSync(virtualDirectory: virtual))
        }
    ) {
        self.scratchRoot = scratchRoot.standardizedFileURL
        self.makeService = makeService
        self.languages = languages
        self.trustStore = trustStore
        self.contexts = contexts
        try? FileManager.default.createDirectory(at: self.scratchRoot, withIntermediateDirectories: true)
        contextsSubscription = contexts.subscribe { [weak self] in self?.contextsChanged() }
    }

    isolated deinit {
        if let contextsSubscription { contexts.unsubscribe(contextsSubscription) }
    }

    /// Whether this kind of server serves documents of `language`.
    public func serves(_ language: DocumentLanguage) -> Bool { servedLanguages.contains(language) }

    /// The folder whose server a document belongs to.
    public func root(for session: DocumentSession) -> URL {
        if session.isUntitled { return scratchRoot }

        guard let context = contexts.context(forFile: session.path) else { return scratchRoot }

        return URL(fileURLWithPath: context.root, isDirectory: true).standardizedFileURL
    }

    /// The service a document is with, if any.
    public func service(for session: DocumentSession) -> SourceKitLanguageService? { homes[session.id]?.service }

    public var runningRoots: [URL] { Array(services.keys) }

    // MARK: Documents

    /// Gives `session` to the server of its place, starting that server if it is not up. Returns
    /// when the document is given; the server may still be starting.
    public func attach(_ session: DocumentSession) async {
        guard managed[session.id] == nil else { return }

        // A change of the document's language moves it: out of the server that had it under the
        // old language, into the one that serves the new, if there is one.
        let subscription = languages.selector(for: session).subscribe { [weak self] _ in self?.languageChanged(session) }
        managed[session.id] = Managed(session: session, languageSubscription: subscription)
        await giveToServer(session)
    }

    /// A folder was opened or closed: a document whose project is now another goes to the server of
    /// that one (and leaves the old, which stops if it has no document left).
    private func contextsChanged() {
        for entry in Array(managed.values) {
            let session = entry.session
            guard let home = homes[session.id], root(for: session) != home.root else { continue }

            release(session)
            Task { await giveToServer(session) }
        }
    }

    private func languageChanged(_ session: DocumentSession) {
        guard managed[session.id] != nil else { return }

        release(session)
        Task { await giveToServer(session) }
    }

    private func giveToServer(_ session: DocumentSession) async {
        guard managed[session.id] != nil, homes[session.id] == nil,
              servedLanguages.contains(languages.selector(for: session).resolved.language) else { return }

        let root = root(for: session)
        let service = services[root] ?? serviceStarted(for: root)
        services[root] = service
        let subscription = session.subscribeToSaves { [weak self] in self?.saved(session) }
        homes[session.id] = Home(root: root, service: service, saveSubscription: subscription)
        notifyReadinessObservers(of: session.id)
        do {
            try await service.open(session)
        } catch {
            // Too large, not Swift: no completion for this one, and no server for it either.
            release(session)

            return
        }
        if service.state == .stopped { await service.start() }
    }

    private func serviceStarted(for root: URL) -> SourceKitLanguageService {
        let service = makeService(root, scratchRoot)
        service.isFallbackRoot = root == scratchRoot || contexts.isWithoutProject(root: root.path)
        if root != scratchRoot {
            service.trustStore = trustStore
            // Read when the question comes, so a prompt set after the service started is used.
            service.trustPrompt = { [weak self] name, root in await self?.trustPrompt?(name, root) ?? .refused }
        }

        service.onReadinessChange = { [weak self, weak service] _ in
            guard let self, let service else { return }

            self.readinessChanged(of: service)
        }
        service.onDiagnostics = { [weak self, weak service] session in
            guard let self, let service, self.homes[session.id]?.service === service else { return }

            self.diagnosticsArrived(for: session, from: service)
        }
        let (languages, served) = (languages, servedLanguages)
        service.sync.languageID = { session in
            let language = languages.selector(for: session).resolved.language

            return served.contains(language) ? language.languageServerID : nil
        }

        return service
    }

    public func detach(_ session: DocumentSession) {
        if let entry = managed.removeValue(forKey: session.id) {
            languages.selector(for: session).unsubscribe(entry.languageSubscription)
        }

        release(session)
    }

    private func release(_ session: DocumentSession) {
        guard let home = homes.removeValue(forKey: session.id) else { return }

        if latestDiagnostics.removeValue(forKey: session.id) != nil { notifyDiagnosticsObservers(of: session.id) }

        session.unsubscribeFromSaves(home.saveSubscription)
        notifyReadinessObservers(of: session.id)
        home.service.close(session)
        if home.root != scratchRoot, home.service.sync.openDocuments.isEmpty, services[home.root] === home.service {
            services.removeValue(forKey: home.root)
            Task { await home.service.stop() }
        }
    }

    /// Saved under another name: the place may be another package.
    private func saved(_ session: DocumentSession) {
        guard let home = homes[session.id], root(for: session) != home.root else { return }

        release(session)
        Task { await giveToServer(session) }
    }

    public func stopAll() async {
        let running = Array(services.values)
        homes.removeAll()
        services.removeAll()
        for service in running { await service.stop() }
    }

    /// Ends every server now (the application is quitting).
    public func terminateAll() {
        for service in services.values { service.terminateNow() }
        services.removeAll()
        homes.removeAll()
    }

    // MARK: CompletionProviding

    public func completion(for session: DocumentSession, caret: @MainActor () -> Int) async -> CompletionOutcome {
        guard let service = homes[session.id]?.service else { return .unavailable(.notRunning) }

        return await service.completion(for: session, caret: caret)
    }

    // MARK: HoverProviding, DefinitionProviding

    public func hover(for session: DocumentSession, offset: @MainActor () -> Int) async -> HoverOutcome {
        guard let service = homes[session.id]?.service else { return .failed(.unavailable(.notRunning)) }

        return await service.hover(for: session, offset: offset)
    }

    public func definition(for session: DocumentSession, offset: @MainActor () -> Int) async -> DefinitionOutcome {
        guard let service = homes[session.id]?.service else { return .failed(.unavailable(.notRunning)) }

        return await service.definition(for: session, offset: offset)
    }

    // MARK: Readiness and trust

    /// What is known about the document's server: nil when it has none.
    public func readiness(for session: DocumentSession) -> ProjectReadiness? { homes[session.id]?.service.readiness }

    @discardableResult
    public func subscribeToReadiness(for session: DocumentSession, _ observer: @escaping @MainActor () -> Void) -> UUID {
        let id = UUID()
        readinessObservers[id] = (session.id, observer)

        return id
    }

    public func unsubscribeFromReadiness(_ id: UUID) {
        readinessObservers.removeValue(forKey: id)
    }

    private func readinessChanged(of service: SourceKitLanguageService) {
        for entry in Array(readinessObservers.values) where homes[entry.document]?.service === service { entry.observer() }
    }

    private func notifyReadinessObservers(of document: DocumentID) {
        for entry in Array(readinessObservers.values) where entry.document == document { entry.observer() }
    }

    /// Whether the document belongs to a project (a package), which is what has a configuration.
    public func isInProject(_ session: DocumentSession) -> Bool {
        homes[session.id].map { $0.root != scratchRoot } ?? false
    }

    /// What the user decided about the configuration of the document's project; nil when undecided.
    public func trustDecision(for session: DocumentSession) -> TrustDecision? {
        guard let home = homes[session.id], home.root != scratchRoot else { return nil }

        return trustStore?.decision(forRoot: DocumentPath.canonical(home.root.path))
    }

    /// Records the decision (nil forgets it, so the question is asked again) and starts the
    /// project's server again, because the server asks only when it starts. A document with no
    /// project has no configuration to decide about.
    public func setTrust(_ decision: TrustDecision?, for session: DocumentSession) {
        guard let home = homes[session.id], home.root != scratchRoot, let trustStore else { return }

        let key = DocumentPath.canonical(home.root.path)
        if let decision { trustStore.record(decision, forRoot: key) } else { trustStore.forget(root: key) }
        let service = home.service
        Task { await service.restart() }
    }

    // MARK: DiagnosticsProviding

    public func diagnostics(for session: DocumentSession) -> DocumentDiagnostics? { latestDiagnostics[session.id] }

    @discardableResult
    public func subscribeToDiagnostics(for session: DocumentSession, _ observer: @escaping @MainActor () -> Void) -> UUID {
        let id = UUID()
        diagnosticsObservers[id] = (session.id, observer)

        return id
    }

    public func unsubscribeFromDiagnostics(_ id: UUID) {
        diagnosticsObservers.removeValue(forKey: id)
    }

    private func diagnosticsArrived(for session: DocumentSession, from service: SourceKitLanguageService) {
        // A report that cannot be read against the text as it is (the document is ahead of the
        // server, or the report names an older version) is not shown; the next one will come.
        guard let report = service.documentDiagnostics(for: session) else { return }

        latestDiagnostics[session.id] = report
        notifyDiagnosticsObservers(of: session.id)
    }

    private func notifyDiagnosticsObservers(of document: DocumentID) {
        for entry in Array(diagnosticsObservers.values) where entry.document == document { entry.observer() }
    }
}
