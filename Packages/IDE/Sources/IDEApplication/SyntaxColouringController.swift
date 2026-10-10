import Foundation

/// Decides, for as long as a document is open, whether it has syntax colours, and starts or stops
/// them when the answer changes: when text grows past the size limit or shrinks back, and when the
/// document becomes another kind of file (Save As).
///
/// Colours cost a copy of the text and a syntax tree. Checking the limit only when the window
/// opens would let any later paste or reload bypass it, so every change is checked: a comparison
/// of two numbers. The controller subscribes before it creates a coordinator, so on a change it is
/// told first and a file that just became too large is never handed to the highlighter.
@MainActor
public final class SyntaxColouringController {
    public enum State: Equatable, Sendable {
        case on
        case off(Reason)
    }

    public enum Reason: Equatable, Sendable {
        case notSwift
        case tooLarge
        /// No highlighter could be made.
        case unavailable
    }

    public private(set) var state: State = .off(.notSwift)
    /// Called after the state changed, with the new state.
    public var onChange: (@MainActor (State) -> Void)?

    private let session: DocumentSession
    private let source: any TextSource
    private let policy: SyntaxPolicy
    private let makeHighlighter: () -> (any SyntaxHighlighter)?
    private let present: @MainActor (SyntaxCoordinator) -> AnyObject?
    private var running: (coordinator: SyntaxCoordinator, presentation: AnyObject?)?
    private var subscription: UUID?

    /// `present` shows a coordinator's colours and returns what keeps them shown (the presenter);
    /// letting go of it must clear them.
    public init(
        session: DocumentSession, source: any TextSource, policy: SyntaxPolicy = .standard,
        makeHighlighter: @escaping () -> (any SyntaxHighlighter)?,
        present: @escaping @MainActor (SyntaxCoordinator) -> AnyObject?
    ) {
        self.session = session
        self.source = source
        self.policy = policy
        self.makeHighlighter = makeHighlighter
        self.present = present
        subscription = session.subscribeToChanges { [weak self] _ in self?.refresh() }
        refresh()
    }

    isolated deinit {
        if let subscription { session.unsubscribeFromChanges(subscription) }
    }

    /// Looks at the document again. Called on every change by itself, and by whoever changes the
    /// document's path (Save As), which is not a change of text.
    public func refresh() {
        let wanted = decide()
        guard wanted != state else { return }
        switch wanted {
        case .on:
            guard let highlighter = makeHighlighter() else {
                return transition(to: .off(.unavailable))
            }
            let coordinator = SyntaxCoordinator(session: session, source: source, highlighter: highlighter)
            running = (coordinator, present(coordinator))
            transition(to: .on)
        case .off:
            stopColouring()
            transition(to: wanted)
        }
    }

    private func decide() -> State {
        guard session.path.hasSuffix(".swift") else { return .off(.notSwift) }
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
        current.presentation = nil
        current.coordinator.stop()
    }

    private func transition(to new: State) {
        state = new
        onChange?(new)
    }
}
