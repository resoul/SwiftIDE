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
public final class LanguageServices: CompletionProviding {
    public typealias MakeService = @MainActor (_ root: URL, _ virtualDirectory: URL) -> SourceKitLanguageService

    private struct Managed {
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
    private let servedLanguages: Set<DocumentLanguage> = [.swift]
    private var services: [URL: SourceKitLanguageService] = [:]
    private var homes: [DocumentID: Home] = [:]
    private var managed: [DocumentID: Managed] = [:]

    public init(
        scratchRoot: URL, languages: DocumentLanguages = DocumentLanguages(),
        makeService: @escaping MakeService = { root, virtual in
            SourceKitLanguageService(workspaceRoot: root, sync: OrderedDocumentSync(virtualDirectory: virtual))
        }
    ) {
        self.scratchRoot = scratchRoot.standardizedFileURL
        self.makeService = makeService
        self.languages = languages
        try? FileManager.default.createDirectory(at: self.scratchRoot, withIntermediateDirectories: true)
    }

    /// Whether this kind of server serves documents of `language`.
    public func serves(_ language: DocumentLanguage) -> Bool { servedLanguages.contains(language) }

    /// The folder whose server a document belongs to.
    public func root(for session: DocumentSession) -> URL {
        if session.isUntitled { return scratchRoot }
        return PackageRootLocator.root(forFile: session.path) ?? scratchRoot
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
        managed[session.id] = Managed(languageSubscription: subscription)
        await giveToServer(session)
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
        session.unsubscribeFromSaves(home.saveSubscription)
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
}
