import Foundation
import IDEDomain

/// Problems found by the editor itself, for the languages it can check without a server (JSON, XML,
/// property lists). It looks again a moment after the last edit and when the language changes, off the
/// main thread, and reports the way a server does: a list of problems for a version of the text.
@MainActor
public final class BuiltInDiagnostics: DiagnosticsProviding {
    private final class State {
        var report: DocumentDiagnostics?
        var observers: [UUID: @MainActor () -> Void] = [:]
        var pending: Task<Void, Never>?
        var changeSubscription: UUID?
        var languageSubscription: UUID?
    }

    private let languages: DocumentLanguages
    private let checker: any SyntaxChecking
    private let delay: Duration
    private var states: [DocumentID: State] = [:]

    public init(
        languages: DocumentLanguages,
        checker: any SyntaxChecking = BuiltInChecker(),
        delay: Duration = .milliseconds(350)
    ) {
        self.languages = languages
        self.checker = checker
        self.delay = delay
    }

    /// Whether the document's language is one this checks.
    public func supports(_ session: DocumentSession) -> Bool {
        checker.supports(languages.selector(for: session).resolved.language)
    }

    public func diagnostics(for session: DocumentSession) -> DocumentDiagnostics? {
        guard supports(session) else { return nil }

        return state(for: session).report
    }

    @discardableResult
    public func subscribeToDiagnostics(
        for session: DocumentSession,
        _ observer: @escaping @MainActor () -> Void
    ) -> UUID {
        let id = UUID()
        state(for: session).observers[id] = observer

        return id
    }

    public func unsubscribeFromDiagnostics(_ id: UUID) {
        for state in states.values { state.observers[id] = nil }
    }

    /// The document is closed: nothing is watched for it any more.
    public func forget(_ session: DocumentSession) {
        guard let state = states.removeValue(forKey: session.id) else { return }

        state.pending?.cancel()
        if let id = state.changeSubscription { session.unsubscribeFromChanges(id) }
        if let id = state.languageSubscription { languages.selector(for: session).unsubscribe(id) }
    }

    private func state(for session: DocumentSession) -> State {
        if let existing = states[session.id] { return existing }

        let made = State()
        states[session.id] = made
        made.changeSubscription = session.subscribeToChanges { [weak self, weak session] _ in
            guard let self, let session else { return }

            schedule(session, after: delay)
        }
        made.languageSubscription = languages.selector(for: session).subscribe { [weak self, weak session] _ in
            guard let self, let session else { return }

            schedule(session, after: .zero)
        }
        schedule(session, after: .zero)

        return made
    }

    private func schedule(_ session: DocumentSession, after wait: Duration) {
        guard let state = states[session.id] else { return }

        state.pending?.cancel()
        state.pending = Task { [weak self, weak session] in
            if wait > .zero { try? await Task.sleep(for: wait) }

            guard !Task.isCancelled, let self, let session else { return }

            await check(session)
        }
    }

    private func check(_ session: DocumentSession) async {
        guard let state = states[session.id] else { return }

        let language = languages.selector(for: session).resolved.language
        guard checker.supports(language) else {
            if state.report != nil {
                state.report = nil
                notify(state)
            }

            return
        }

        let snapshot = session.snapshot()
        let fileName = (session.path as NSString).lastPathComponent
        let directory = session.isUntitled ? nil : (session.path as NSString).deletingLastPathComponent
        let checker = checker
        let items = await Task.detached(priority: .utility) {
            await checker.check(
                Array(snapshot.text.utf16),
                language: language,
                fileName: fileName,
                directory: directory
            )
        }.value
        guard !Task.isCancelled, states[session.id] === state else { return }

        let report = DocumentDiagnostics(items: items, version: snapshot.version, isVerified: true)
        guard report != state.report else { return }

        state.report = report
        notify(state)
    }

    private func notify(_ state: State) {
        for observer in Array(state.observers.values) { observer() }
    }
}
