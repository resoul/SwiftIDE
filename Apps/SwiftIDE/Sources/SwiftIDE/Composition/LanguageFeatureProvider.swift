import Foundation
import IDEApplication
import LanguageInfrastructure

/// What one editor asks for besides completion: descriptions and definitions from the language server,
/// and problems from the server — or, for a language the editor checks itself (JSON, XML), from its own
/// check. One object to hand to the editor, so the editor does not need to know which is which.
@MainActor
final class LanguageFeatureProvider: HoverProviding, DefinitionProviding, DiagnosticsProviding {
    private let server: LanguageServices
    private let builtIn: BuiltInDiagnostics
    /// What lays out a language's text (JSON, XML, TOML, YAML, shell).
    let formatter: any DocumentFormatter

    init(server: LanguageServices, builtIn: BuiltInDiagnostics, formatter: any DocumentFormatter) {
        self.server = server
        self.builtIn = builtIn
        self.formatter = formatter
    }

    func hover(for session: DocumentSession, offset: @MainActor () -> Int) async -> HoverOutcome {
        await server.hover(for: session, offset: offset)
    }

    func definition(for session: DocumentSession, offset: @MainActor () -> Int) async -> DefinitionOutcome {
        await server.definition(for: session, offset: offset)
    }

    func diagnostics(for session: DocumentSession) -> DocumentDiagnostics? {
        builtIn.supports(session) ? builtIn.diagnostics(for: session) : server.diagnostics(for: session)
    }

    /// Both are listened to, and each answers only for the languages that are its own; the observer
    /// is told whichever speaks.
    @discardableResult
    func subscribeToDiagnostics(for session: DocumentSession, _ observer: @escaping @MainActor () -> Void) -> UUID {
        let id = UUID()
        let first = server.subscribeToDiagnostics(for: session, observer)
        let second = builtIn.subscribeToDiagnostics(for: session, observer)
        subscriptions[id] = [first, second]

        return id
    }

    func unsubscribeFromDiagnostics(_ id: UUID) {
        for part in subscriptions.removeValue(forKey: id) ?? [] {
            server.unsubscribeFromDiagnostics(part)
            builtIn.unsubscribeFromDiagnostics(part)
        }
    }

    func forget(_ session: DocumentSession) { builtIn.forget(session) }

    private var subscriptions: [UUID: [UUID]] = [:]
}
