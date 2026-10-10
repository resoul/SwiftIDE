import Foundation
import IDEDomain

/// Decides, for as long as a document is open, whether it has syntax colours, and starts or stops
/// them when the answer changes: when text grows past the size limit or shrinks back, and when the
/// document becomes another kind of file (Save As).
///
/// Colours cost a copy of the text and a syntax tree. Checking the limit only when the window
/// opens would let any later paste or reload bypass it, so every change is checked: a comparison
/// of two numbers. The controller subscribes before it creates a coordinator, so on a change it is
/// told first and a file that just became too large is never handed to the highlighter.
///
/// Which languages have colours is the highlighter's matter (`supportedLanguages`); which language
/// the document is, the document's (`DocumentLanguageSelector`). Another language stops the old
/// colours and starts the new ones, with the text and its version untouched.
@MainActor
public final class SyntaxColouringController {
    public enum State: Equatable, Sendable {
        case on
        case off(Reason)
    }

    public enum Reason: Equatable, Sendable {
        /// The document's language has no grammar here (plain text, or a language not yet supported).
        case languageNotSupported
        case tooLarge
        /// No highlighter could be made.
        case unavailable
    }

    public private(set) var state: State = .off(.languageNotSupported)
    /// Called after the state changed, with the new state.
    public var onChange: (@MainActor (State) -> Void)?

    private let session: DocumentSession
    private let source: any TextSource
    private let policy: SyntaxPolicy
    private let makeHighlighter: (DocumentLanguage) -> (any SyntaxHighlighter)?
    private let present: @MainActor (SyntaxCoordinator) -> AnyObject?
    private var running: (coordinator: SyntaxCoordinator, presentation: AnyObject?)?
    private let languages: DocumentLanguageSelector
    private let supportedLanguages: Set<DocumentLanguage>
    private var subscription: UUID?
    private var languageSubscription: UUID?
    /// The language the colours now shown were made for.
    private var colouredLanguage: DocumentLanguage?

    /// `present` shows a coordinator's colours and returns what keeps them shown (the presenter);
    /// letting go of it must clear them.
    public convenience init(
        session: DocumentSession,
        source: any TextSource,
        policy: SyntaxPolicy = .standard,
        languages: DocumentLanguageSelector? = nil,
        supportedLanguages: Set<DocumentLanguage> = [.swift],
        makeHighlighter: @escaping () -> (any SyntaxHighlighter)?,
        present: @escaping @MainActor (SyntaxCoordinator) -> AnyObject?
    ) {
        self.init(
            session: session,
            source: source,
            policy: policy,
            languages: languages,
            supportedLanguages: supportedLanguages,
            makeHighlighter: { _ in makeHighlighter() },
            present: present
        )
    }

    /// `makeHighlighter` is given the language the colours are for.
    public init(
        session: DocumentSession,
        source: any TextSource,
        policy: SyntaxPolicy = .standard,
        languages: DocumentLanguageSelector? = nil,
        supportedLanguages: Set<DocumentLanguage> = [.swift],
        makeHighlighter: @escaping (DocumentLanguage) -> (any SyntaxHighlighter)?,
        present: @escaping @MainActor (SyntaxCoordinator) -> AnyObject?
    ) {
        self.languages = languages ?? DocumentLanguageSelector(session: session)
        self.supportedLanguages = supportedLanguages
        self.session = session
        self.source = source
        self.policy = policy
        self.makeHighlighter = makeHighlighter
        self.present = present
        subscription = session.subscribeToChanges { [weak self] _ in self?.refresh() }
        languageSubscription = self.languages.subscribe { [weak self] _ in self?.refresh() }
        refresh()
    }

    isolated deinit {
        if let subscription { session.unsubscribeFromChanges(subscription) }
        if let languageSubscription { languages.unsubscribe(languageSubscription) }
    }

    /// Whether there are colours for a language at all (not whether they are on now).
    public func hasColours(for language: DocumentLanguage) -> Bool { supportedLanguages.contains(language) }

    /// Looks at the document again. Called on every change by itself, and by whoever changes the
    /// document's path (Save As), which is not a change of text.
    public func refresh() {
        let language = languages.resolved.language
        let wanted = decide(for: language)
        // Colours made for another language are not kept, even if there are colours for this one too.
        let restart = wanted == .on && state == .on && language != colouredLanguage
        guard wanted != state || restart else { return }

        switch wanted {
        case .on:
            stopColouring()
            guard let highlighter = makeHighlighter(language) else {
                return transition(to: .off(.unavailable))
            }

            let coordinator = SyntaxCoordinator(session: session, source: source, highlighter: highlighter)
            running = (coordinator, present(coordinator))
            colouredLanguage = language
            transition(to: .on)
        case .off:
            stopColouring()
            transition(to: wanted)
        }
    }

    private func decide(for language: DocumentLanguage) -> State {
        guard supportedLanguages.contains(language) else { return .off(.languageNotSupported) }

        let length = session.utf16Length
        switch state {
        case .off(.tooLarge):
            return policy.allowsResuming(documentLength: length) ? .on : .off(.tooLarge)
        case .off(.unavailable):
            // A highlighter that could not be made is tried again only when the file changes kind.
            return .off(.unavailable)
        default:
            return policy.allowsColouring(documentLength: length) ? .on : .off(.tooLarge)
        }
    }

    private func stopColouring() {
        guard var current = running else { return }

        running = nil
        // The presenter goes first, clearing its colours while the coordinator still exists; then
        // the coordinator lets the highlighter drop its tree and its copy of the text.
        colouredLanguage = nil
        current.presentation = nil
        current.coordinator.stop()
    }

    private func transition(to new: State) {
        state = new
        onChange?(new)
    }
}
