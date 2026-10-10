import Foundation
import IDEDomain

/// The small window that says what is under the pointer or the caret.
@MainActor
public protocol HoverPresenting: AnyObject {
    /// Shows `text` under the first character of `anchor`, replacing what is shown.
    func show(_ text: String, anchor: UTF16TextRange)
    func dismiss()
}

/// What a language server could not do, in words for a tooltip or a status line.
public extension CompletionStatus {
    init(_ reason: LanguageServiceUnavailable) {
        switch reason {
        case .starting: self = .starting
        case .restarting: self = .restarting
        case .documentNotSynced: self = .notReady
        case .failed, .notRunning: self = .unavailable
        }
    }
}

/// Decides when a description is asked for and when it goes away.
///
/// By pointer: the pointer rests on a word for `dwell`, the description is asked for and shown under
/// the word; moving to another word, leaving the text, typing, scrolling or an edit takes it away.
/// By key: the same for the word at the caret, at once, and with a word when there is nothing to
/// say. What the editor knows itself about the place (the problems found there) is shown first,
/// without waiting for the server.
@MainActor
public final class HoverController {
    private let session: DocumentSession
    private let provider: any HoverProviding
    private weak var presenter: (any HoverPresenting)?
    private let clock: any DelayClock
    private let dwell: Duration
    private let wordAt: @MainActor (Int) -> UTF16TextRange?
    private let localMessages: @MainActor (Int) -> [String]
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var changeSubscription: UUID?
    private var compositionSubscription: UUID?
    /// The word the shown text is about.
    public private(set) var shownAnchor: UTF16TextRange?

    public var isShowing: Bool { shownAnchor != nil }

    /// `wordAt` gives the word under an offset, nil if there is none; `localMessages` the problems
    /// the editor itself knows at an offset.
    public init(
        session: DocumentSession,
        provider: any HoverProviding,
        presenter: any HoverPresenting,
        clock: any DelayClock = SystemDelayClock(),
        dwell: Duration = .milliseconds(500),
        wordAt: @escaping @MainActor (Int) -> UTF16TextRange?,
        localMessages: @escaping @MainActor (Int) -> [String] = { _ in [] }
    ) {
        self.session = session
        self.provider = provider
        self.presenter = presenter
        self.clock = clock
        self.dwell = dwell
        self.wordAt = wordAt
        self.localMessages = localMessages
        changeSubscription = session.subscribeToChanges { [weak self] _ in self?.dismiss() }
        compositionSubscription = session.subscribeToComposition { [weak self] event in
            if event == .began { self?.dismiss() }
        }
    }

    isolated deinit {
        task?.cancel()
        if let changeSubscription { session.unsubscribeFromChanges(changeSubscription) }
        if let compositionSubscription { session.unsubscribeFromComposition(compositionSubscription) }
    }

    // MARK: Events

    /// The pointer is over the character at `offset`, or over nothing of the text (nil).
    public func pointerMoved(to offset: Int?) {
        guard let offset else { return dismiss() }

        // Still on the text being described: nothing changes, even where there is no word.
        if let shown = shownAnchor, offset >= shown.location, offset < max(shown.location + shown.length, shown.location + 1) { return }

        guard let word = wordAt(offset) else { return dismiss() }

        // Still on the word being waited for.
        if pendingAnchor == word { return }

        begin(word, byKey: false)
    }

    /// The user asked by key for the description at the caret.
    public func requestAtCaret(_ offset: Int) {
        guard !session.isComposing else { return }

        let word = wordAt(offset) ?? UTF16TextRange(location: offset, length: 0)
        begin(word, byKey: true)
    }

    /// Anything that makes a description out of place: typing, scrolling, a click, a lost window.
    public func dismiss() {
        task?.cancel()
        task = nil
        pendingAnchor = nil
        generation += 1
        guard shownAnchor != nil else { return }

        shownAnchor = nil
        presenter?.dismiss()
    }

    // MARK: Asking

    private var pendingAnchor: UTF16TextRange?

    private func begin(_ word: UTF16TextRange, byKey: Bool) {
        dismiss()
        pendingAnchor = word
        let mine = generation
        task = Task { @MainActor [weak self, clock, dwell] in
            if !byKey {
                guard (try? await clock.sleep(for: dwell)) != nil else { return }
            }

            await self?.ask(word, byKey: byKey, generation: mine)
        }
    }

    private func ask(_ word: UTF16TextRange, byKey: Bool, generation mine: UInt64) async {
        guard generation == mine else { return }

        let local = localMessages(word.location)
        if !local.isEmpty { present(local.joined(separator: "\n"), word) }

        let outcome = await provider.hover(for: session, offset: { word.location })
        guard generation == mine else { return }

        pendingAnchor = nil
        switch outcome {
        case .content(let content):
            present((local + [content.text]).joined(separator: "\n\n"), content.range.flatMap { $0.length > 0 ? $0 : nil } ?? word)
        case .nothing:
            if local.isEmpty, byKey { present("No quick help here", word) }
        case .failed(.unavailable(let reason)):
            if local.isEmpty, byKey { present(Self.words(for: reason), word) }
        case .failed(.stale), .failed(.suppressedByComposition):
            break
        }
    }

    private func present(_ text: String, _ anchor: UTF16TextRange) {
        shownAnchor = anchor
        presenter?.show(text, anchor: anchor)
    }

    /// Why there is nothing, in the words the completion list uses.
    static func words(for reason: LanguageServiceUnavailable) -> String {
        switch CompletionStatus(reason) {
        case .starting: "SourceKit is starting…"
        case .restarting: "SourceKit is restarting…"
        case .notReady: "SourceKit is not ready yet"
        default: "SourceKit is not available"
        }
    }
}
