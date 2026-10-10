import Foundation
import IDEDomain

/// Where a document's language came from. The order of the cases is the order of precedence.
public enum LanguageSource: Equatable, Sendable {
    /// The user chose it for this document.
    case manual
    /// The settings of the build target the file belongs to say so.
    case projectContext
    /// The file name says so.
    case fileName
    /// The file name fits several languages and one of them was taken for now (`.h`).
    case provisionalFileName
    /// Nothing says; the text is plain.
    case unknown
}

/// The language a document is treated as, and the revision of that decision: every consumer that
/// keeps results (colours, completion, diagnostics) can tell they were made for another language.
public struct ResolvedLanguage: Equatable, Sendable {
    public let language: DocumentLanguage
    public let source: LanguageSource
    /// Grows each time the language changes; the first decision is 1. A change of source alone
    /// (the user confirms what the name already said) keeps it.
    public let revision: Int

    public init(language: DocumentLanguage, source: LanguageSource, revision: Int) {
        self.language = language
        self.source = source
        self.revision = revision
    }
}

/// Remembers languages the user chose, by file path. The text, its version, its dirty state and
/// Undo have nothing to do with it.
@MainActor
public protocol LanguageOverrideStore: AnyObject {
    func override(forPath path: String) -> DocumentLanguage?
    /// Nil forgets the choice.
    func setOverride(_ language: DocumentLanguage?, forPath path: String)
}

@MainActor
public final class MemoryLanguageOverrideStore: LanguageOverrideStore {
    private var overrides: [String: DocumentLanguage] = [:]
    public init() {}
    public func override(forPath path: String) -> DocumentLanguage? { overrides[path] }
    public func setOverride(_ language: DocumentLanguage?, forPath path: String) { overrides[path] = language }
}

/// The one place that says what language a document is: the manual choice, else the build
/// context, else the file name. Colours, language servers and commands ask here and do not look at
/// extensions themselves.
@MainActor
public final class DocumentLanguageSelector {
    private let session: DocumentSession
    private let store: any LanguageOverrideStore
    private let context: @MainActor (DocumentSession) -> DocumentLanguage?
    private var chosen: DocumentLanguage?
    private var knownPath: String
    private var knownUntitled: Bool
    private var observers: [UUID: @MainActor (ResolvedLanguage) -> Void] = [:]
    private var saveSubscription: UUID?
    public private(set) var resolved: ResolvedLanguage

    /// `context` gives the language the build settings of the document's target name, if known.
    public init(
        session: DocumentSession,
        store: any LanguageOverrideStore = MemoryLanguageOverrideStore(),
        context: @escaping @MainActor (DocumentSession) -> DocumentLanguage? = { _ in nil }
    ) {
        self.session = session
        self.store = store
        self.context = context
        knownPath = session.path
        knownUntitled = session.isUntitled
        chosen = session.isUntitled ? nil : store.override(forPath: DocumentPath.canonical(session.path))
        resolved = ResolvedLanguage(language: .plainText, source: .unknown, revision: 0)
        resolved = decide(revision: 1)
        // A save, and above all a save under another name, may change what the name says.
        saveSubscription = session.subscribeToSaves { [weak self] in self?.pathMayHaveChanged() }
    }

    isolated deinit {
        if let saveSubscription { session.unsubscribeFromSaves(saveSubscription) }
    }

    /// The language the user chose, if they did.
    public var override: DocumentLanguage? { chosen }

    /// Chooses a language for the document; nil goes back to deciding by context and name.
    public func setOverride(_ language: DocumentLanguage?) {
        chosen = language
        remember(language, forPath: session.path)
        recompute()
    }

    /// Looks again at what decides the language: after the build context changed, say.
    public func contextDidChange() {
        recompute()
    }

    @discardableResult
    public func subscribe(_ observer: @escaping @MainActor (ResolvedLanguage) -> Void) -> UUID {
        let id = UUID()
        observers[id] = observer

        return id
    }

    public func unsubscribe(_ id: UUID) {
        observers.removeValue(forKey: id)
    }

    // MARK: Deciding

    private func pathMayHaveChanged() {
        if session.path != knownPath {
            // The choice belongs to the document, not to the name it had.
            if chosen != nil {
                if !knownUntitled { store.setOverride(nil, forPath: DocumentPath.canonical(knownPath)) }
                if !session.isUntitled { store.setOverride(chosen, forPath: DocumentPath.canonical(session.path)) }
            } else if !session.isUntitled {
                chosen = store.override(forPath: DocumentPath.canonical(session.path))
            }

            knownPath = session.path
            knownUntitled = session.isUntitled
        }

        recompute()
    }

    private func remember(_ language: DocumentLanguage?, forPath path: String) {
        guard !session.isUntitled else { return }

        // The key is the name the registry knows the file by, so a link and its target agree.
        store.setOverride(language, forPath: DocumentPath.canonical(path))
    }

    private func recompute() {
        let next = decide(revision: resolved.revision + 1)
        guard next.language != resolved.language || next.source != resolved.source else { return }

        // Only another language makes what was made for the old one out of date.
        let revision = next.language == resolved.language ? resolved.revision : resolved.revision + 1
        let updated = ResolvedLanguage(language: next.language, source: next.source, revision: revision)
        resolved = updated
        for observer in Array(observers.values) { observer(updated) }
    }

    private func decide(revision: Int) -> ResolvedLanguage {
        if let chosen { return ResolvedLanguage(language: chosen, source: .manual, revision: revision) }
        if let fromContext = context(session) {
            return ResolvedLanguage(language: fromContext, source: .projectContext, revision: revision)
        }

        let guess = DocumentLanguage.guess(forPath: session.path)
        let source: LanguageSource = guess.language == .plainText ? .unknown : (guess.isProvisional ? .provisionalFileName : .fileName)

        return ResolvedLanguage(language: guess.language, source: source, revision: revision)
    }
}

/// What the subtitle says about a document's language: the language, how sure that is, and, for a
/// chosen language that has less than the full set, what is missing. Choosing a language is not
/// the same as having colours or language features for it.
public enum LanguageSupportNote {
    public static func parts(for resolved: ResolvedLanguage, hasColours: Bool, hasLanguageFeatures: Bool) -> [String] {
        let name = resolved.language.displayName
        var parts: [String]
        switch resolved.source {
        case .manual: parts = ["\(name) (chosen)"]
        case .provisionalFileName: parts = ["\(name) (guess)"]
        case .projectContext, .fileName, .unknown: parts = [name]
        }
        guard resolved.language != .plainText else { return parts }

        if !hasColours { parts.append("no syntax colours") }
        if !hasLanguageFeatures { parts.append("no code completion") }

        return parts
    }
}

/// The selectors of all open documents, so that every consumer of one document's language asks
/// the same object.
@MainActor
public final class DocumentLanguages {
    private let store: any LanguageOverrideStore
    private let context: @MainActor (DocumentSession) -> DocumentLanguage?
    private var selectors: [DocumentID: DocumentLanguageSelector] = [:]

    public init(
        store: any LanguageOverrideStore = MemoryLanguageOverrideStore(),
        context: @escaping @MainActor (DocumentSession) -> DocumentLanguage? = { _ in nil }
    ) {
        self.store = store
        self.context = context
    }

    public func selector(for session: DocumentSession) -> DocumentLanguageSelector {
        if let existing = selectors[session.id] { return existing }
        let made = DocumentLanguageSelector(session: session, store: store, context: context)
        selectors[session.id] = made

        return made
    }

    /// The document is closed.
    public func forget(_ session: DocumentSession) {
        selectors.removeValue(forKey: session.id)
    }
}
