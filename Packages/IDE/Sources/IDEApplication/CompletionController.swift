import Foundation
import IDEDomain

public struct CompletionRow: Equatable, Sendable {
    public let label: String
    public let detail: String?
    public let kind: CompletionKind
}

/// The list the user sees. It shows what it is told and decides nothing.
@MainActor
public protocol CompletionPresenting: AnyObject {
    /// Shows `rows` below the character at `anchorOffset` (where the word being completed begins).
    func present(rows: [CompletionRow], selected: Int, anchorOffset: Int)
    func select(_ index: Int)
    func dismiss()
    /// Shows one line saying why there is no list, under the character at `anchorOffset`.
    func showStatus(_ status: CompletionStatus, anchorOffset: Int)
}

/// What the controller needs from the view it completes in.
public struct CompletionEnvironment {
    /// The caret, or nil when there is none or text is selected.
    public var caret: @MainActor () -> Int?
    public var text: @MainActor (UTF16TextRange) -> String
    public var setCaret: @MainActor (Int) -> Void

    public init(
        caret: @escaping @MainActor () -> Int?, text: @escaping @MainActor (UTF16TextRange) -> String,
        setCaret: @escaping @MainActor (Int) -> Void
    ) {
        self.caret = caret
        self.text = text
        self.setCaret = setCaret
    }
}

/// When completion appears, what it shows and what accepting it does (ADR-022).
///
/// It appears after a typed ".", or when asked. It is asked of the provider once, then the list
/// narrows as the user types the start of a word (and is asked again if the provider says its list
/// was cut short). Anything else the user does ends it: a character that is not part of a word, a
/// caret that moves, an edit that is not typing at the end of the word, marked text.
@MainActor
public final class CompletionController {
    private struct Context {
        /// Where the word being completed begins.
        var anchor: Int
        /// Where the typed part of it ends: the caret.
        var caret: Int
        var items: [CompletionItem] = []
        /// Where the caret was when the answer came: the coordinates of the ranges the items name.
        var answerCaret = 0
        var isIncomplete = true
        var visible: [CompletionItem] = []
        var selected = 0
        var hasAnswer = false
        /// Asked for by the user (not started by typing a dot): what is said about an empty answer.
        var isManual = false
        /// Answers so far that were empty and "cut short": a server that is not ready yet says that.
        var emptyAnswers = 0
    }

    private let session: DocumentSession
    private let provider: any CompletionProviding
    private let environment: CompletionEnvironment
    private weak var presenter: (any CompletionPresenting)?
    private let maximumRows: Int
    private let clock: any DelayClock
    private let timeout: Duration
    private let waitingNotice: Duration
    private let statusDuration: Duration
    private let retryDelay: Duration
    private let maximumEmptyAnswers: Int
    private var retry: Task<Void, Never>?
    private var context: Context?
    private var request: Task<Void, Never>?
    /// Runs alongside a request: puts up "waiting", then gives up on it.
    private var watch: Task<Void, Never>?
    /// A status line is on screen; the next thing the user does takes it down.
    private var statusIsShowing = false
    private var statusTimer: Task<Void, Never>?
    private var token: UInt64 = 0
    private var changeSubscription: UUID?
    private var compositionSubscription: UUID?

    public init(
        session: DocumentSession, provider: any CompletionProviding, environment: CompletionEnvironment,
        presenter: any CompletionPresenting, maximumRows: Int = 200, clock: any DelayClock = SystemDelayClock(),
        timeout: Duration = .seconds(5), waitingNotice: Duration = .milliseconds(300), statusDuration: Duration = .seconds(2),
        retryDelay: Duration = .milliseconds(250), maximumEmptyAnswers: Int = 3
    ) {
        self.retryDelay = retryDelay
        self.maximumEmptyAnswers = maximumEmptyAnswers
        self.clock = clock
        self.timeout = timeout
        self.waitingNotice = waitingNotice
        self.statusDuration = statusDuration
        self.session = session
        self.provider = provider
        self.environment = environment
        self.presenter = presenter
        self.maximumRows = maximumRows
        changeSubscription = session.subscribeToChanges { [weak self] change in self?.changed(change) }
        compositionSubscription = session.subscribeToComposition { [weak self] event in
            if event == .began { self?.dismiss() }
        }
    }

    isolated deinit {
        request?.cancel()
        watch?.cancel()
        retry?.cancel()
        statusTimer?.cancel()
        if let changeSubscription { session.unsubscribeFromChanges(changeSubscription) }
        if let compositionSubscription { session.unsubscribeFromComposition(compositionSubscription) }
    }

    /// The completion has started (a request may be out), whether or not a list is showing.
    public var isActive: Bool { context != nil }

    /// A list is on screen: keys that choose from it are for it.
    public var isShowing: Bool { !(context?.visible.isEmpty ?? true) }

    // MARK: Starting

    /// Completion at the caret, asked for by the user.
    public func requestManually() {
        guard !session.isComposing, let caret = environment.caret(), caret >= 0, caret <= session.utf16Length else { return }
        let window = UTF16TextRange(location: max(0, caret - 128), length: caret - max(0, caret - 128))
        let before = Array(environment.text(window).utf16)
        var start = before.count
        while start > 0, Self.isWordUnit(before[start - 1]) { start -= 1 }
        begin(anchor: caret - (before.count - start), caret: caret, manual: true)
    }

    private func begin(anchor: Int, caret: Int, manual: Bool = false) {
        context = Context(anchor: anchor, caret: caret, isManual: manual)
        presenter?.dismiss()
        ask()
    }

    private func changed(_ change: DocumentChangeSet) {
        removeStatus()
        if context != nil {
            follow(change)
        } else {
            maybeStartAfterDot(change)
        }
    }

    private func maybeStartAfterDot(_ change: DocumentChangeSet) {
        guard change.origin == .typing, change.edits.count == 1, !session.isComposing else { return }
        let edit = change.edits[0]
        guard edit.range.length == 0, edit.replacement == ".", edit.range.location > 0 else { return }
        let lookBack = min(edit.range.location, 64)
        let before = Array(environment.text(UTF16TextRange(location: edit.range.location - lookBack, length: lookBack)).utf16)
        guard Self.endsMemberBase(before) else { return }
        begin(anchor: edit.range.location + 1, caret: edit.range.location + 1)
    }

    /// `x.`, `foo().`, `a[0].`, `x?.`; not `1.`, not `..`, not `. ` after a space.
    static func endsMemberBase(_ units: [UInt16]) -> Bool {
        guard let last = units.last else { return false }
        if let scalar = Unicode.Scalar(last), ")]?!}>".unicodeScalars.contains(scalar) { return true }
        guard isWordUnit(last) else { return false }
        var start = units.count
        while start > 0, isWordUnit(units[start - 1]) { start -= 1 }
        // A run of digits alone is a number; one that starts with a letter or "_" is a name.
        let first = units[start]
        return !(first >= 0x30 && first <= 0x39)
    }

    // MARK: While it is open

    private func follow(_ change: DocumentChangeSet) {
        guard var current = context else { return }
        // Only typing at the end of the word keeps it going: a character added to it, or taken off.
        guard change.origin == .typing, change.edits.count == 1 else { return dismiss() }
        let edit = change.edits[0]
        let end = edit.range.location + edit.range.length
        let units = Array(edit.replacement.utf16)
        guard end == current.caret, edit.range.location >= current.anchor, units.allSatisfy(Self.isWordUnit) else {
            return dismiss()
        }
        current.caret = edit.range.location + units.count
        context = current
        refilter()
        if !current.hasAnswer || current.isIncomplete { ask() }
    }

    /// Chooses among the rows by `delta`, wrapping at the ends.
    public func moveSelection(by delta: Int) {
        guard var current = context, !current.visible.isEmpty else { return }
        let count = current.visible.count
        current.selected = ((current.selected + delta) % count + count) % count
        context = current
        presenter?.select(current.selected)
    }

    /// Points the selection at a row (a click).
    public func select(row: Int) {
        guard var current = context, current.visible.indices.contains(row) else { return }
        current.selected = row
        context = current
        presenter?.select(row)
    }

    /// Replaces the word typed so far with the selected row. False if there is nothing to accept.
    @discardableResult
    public func accept() -> Bool {
        guard let current = context, current.visible.indices.contains(current.selected) else { return false }
        guard environment.caret() == current.caret else {
            dismiss()
            return false
        }
        let item = current.visible[current.selected]
        let text = item.insertText ?? item.label
        guard let range = Self.replacement(of: item, in: current) else {
            dismiss()
            return false
        }
        dismiss()   // before the edit: it is the controller's own, not the user's typing
        do {
            try session.apply([DocumentEdit(range: range, replacement: text)], expectedVersion: session.version, origin: .languageAction)
        } catch {
            return false
        }
        environment.setCaret(range.location + Self.caretOffset(afterInserting: text, for: item))
        return true
    }

    public func dismiss() {
        request?.cancel()
        request = nil
        watch?.cancel()
        watch = nil
        retry?.cancel()
        statusTimer?.cancel()
        statusIsShowing = false
        token += 1
        context = nil
        presenter?.dismiss()
    }

    /// The completion is over and the user is told why there is no list.
    private func finish(with status: CompletionStatus) {
        guard let current = context else { return }
        let anchor = current.anchor
        dismiss()
        presenter?.showStatus(status, anchorOffset: anchor)
        statusIsShowing = true
        statusTimer = Task { @MainActor [weak self, clock, statusDuration] in
            guard (try? await clock.sleep(for: statusDuration)) != nil else { return }
            self?.removeStatus()
        }
    }

    private func removeStatus() {
        guard statusIsShowing else { return }
        statusTimer?.cancel()
        statusIsShowing = false
        presenter?.dismiss()
    }

    /// Tell the controller that the view's selection changed. A caret that is no longer at the end
    /// of the word ends the completion. Looked at a turn later: the edit and the selection of one
    /// keystroke are not reported in a fixed order.
    public func selectionDidChange() {
        removeStatus()
        guard context != nil else { return }
        Task { @MainActor [weak self] in
            guard let self, let current = self.context else { return }
            if self.environment.caret() != current.caret { self.dismiss() }
        }
    }

    // MARK: Asking the provider

    private func ask() {
        request?.cancel()
        watch?.cancel()
        retry?.cancel()
        token += 1
        let mine = token
        watch = Task { @MainActor [weak self, clock, waitingNotice, timeout] in
            guard (try? await clock.sleep(for: waitingNotice)) != nil else { return }
            self?.noticeWaiting(mine)
            guard (try? await clock.sleep(for: timeout - waitingNotice)) != nil else { return }
            self?.giveUp(mine)
        }
        let provider = provider, session = session
        request = Task { @MainActor [weak self] in
            let outcome = await provider.completion(for: session, caret: { self?.context?.caret ?? -1 })
            guard let self, self.token == mine, self.context != nil else { return }
            self.watch?.cancel()
            switch outcome {
            case .items(let items, let cutShort):
                // Nothing yet and "more to come": SourceKit-LSP answers so while it is still busy
                // (a server under load, a package just opened). Ask again shortly rather than leave
                // the user with nothing until they type; but not for ever.
                var incomplete = cutShort
                if items.isEmpty && cutShort {
                    if false {
                        self.context?.emptyAnswers += 1
                        self.askAgainSoon(mine)
                        return
                    }
                    incomplete = false
                }
                self.context?.items = items
                if let caret = self.context?.caret { self.context?.answerCaret = caret }
                self.context?.isIncomplete = incomplete
                self.context?.hasAnswer = true
                self.context?.selected = 0
                self.refilter()
                // Nothing to offer, and no more to come: the user is told, if they asked.
                if let current = self.context, current.visible.isEmpty, !incomplete, current.isManual {
                    self.finish(with: .noSuggestions)
                } else if let current = self.context, current.visible.isEmpty, !incomplete, items.isEmpty {
                    self.dismiss()
                }
            case .unavailable(let reason):
                self.explain(reason)
            case .suppressedByComposition:
                self.dismiss()
            case .stale:
                break   // a newer request is on its way, or the situation ended and dismissed us
            }
        }
    }

    private func askAgainSoon(_ mine: UInt64) {
        retry = Task { @MainActor [weak self, clock, retryDelay] in
            guard (try? await clock.sleep(for: retryDelay)) != nil else { return }
            guard let self, self.token == mine, self.context != nil else { return }
            self.ask()
        }
    }

    /// Why the server could not be asked. After a dot the user did not ask for anything, so a
    /// document with no server at all (a text file) is left alone.
    private func explain(_ reason: LanguageServiceUnavailable) {
        switch reason {
        case .starting: finish(with: .starting)
        case .restarting: finish(with: .restarting)
        case .documentNotSynced: finish(with: .notReady)
        case .failed: finish(with: .unavailable)
        case .notRunning:
            if context?.isManual == true { finish(with: .unavailable) } else { dismiss() }
        }
    }

    /// The answer is slow: say so, unless there is a list to look at already.
    private func noticeWaiting(_ mine: UInt64) {
        guard token == mine, let current = context, current.visible.isEmpty else { return }
        presenter?.showStatus(.waiting, anchorOffset: current.anchor)
    }

    /// The answer did not come in time: withdraw the question. A list that is on screen stays (it
    /// was cut short, but it is something); otherwise the user is told.
    private func giveUp(_ mine: UInt64) {
        guard token == mine, let current = context else { return }
        request?.cancel()
        token += 1
        if current.visible.isEmpty {
            finish(with: .notResponding)
        } else {
            context?.isIncomplete = false
        }
    }

    // MARK: Narrowing the list

    private func refilter() {
        guard var current = context, current.hasAnswer else { return }
        let prefix = current.caret > current.anchor
            ? environment.text(UTF16TextRange(location: current.anchor, length: current.caret - current.anchor))
            : ""
        let chosen = current.visible.indices.contains(current.selected) ? current.visible[current.selected] : nil
        // An item that names text the caret is not in (any more) cannot be applied; it is not offered.
        let usable = current.items.filter { Self.replacement(of: $0, in: current) != nil }
        current.visible = Self.filter(usable, prefix: prefix, limit: maximumRows)
        // Keep the same row selected while the list narrows around it, else begin at the top.
        current.selected = chosen.flatMap { c in current.visible.firstIndex(of: c) } ?? 0
        context = current
        if current.visible.isEmpty {
            presenter?.dismiss()
        } else {
            presenter?.present(
                rows: current.visible.map { CompletionRow(label: $0.label, detail: $0.detail, kind: $0.kind) },
                selected: current.selected, anchorOffset: current.anchor
            )
        }
    }

    /// The text an item replaces, in the document as it is now: the range the server named, moved by
    /// what was typed at the caret since the answer (typing is inside the range, so only its end
    /// moves), or the word typed so far when the server named none. Nil if that range does not
    /// contain the caret, which no longer is an edit of the word being completed.
    private static func replacement(of item: CompletionItem, in context: Context) -> UTF16TextRange? {
        guard let named = item.replacementRange else {
            return UTF16TextRange(location: context.anchor, length: context.caret - context.anchor)
        }
        let start = named.location
        let end = named.location + named.length + (context.caret - context.answerCaret)
        guard start >= 0, start <= context.caret, context.caret <= end else { return nil }
        return UTF16TextRange(location: start, length: end - start)
    }

    /// Rows that match the typed start of a word: the exact-case start first, then the start in any
    /// case, then the start of a later word of the name; in the server's order within each.
    static func filter(_ items: [CompletionItem], prefix: String, limit: Int) -> [CompletionItem] {
        guard !prefix.isEmpty else { return Array(items.sorted(by: Self.serverOrder).prefix(limit)) }
        let lowered = prefix.lowercased()
        var ranked: [(rank: Int, item: CompletionItem)] = []
        for item in items {
            let text = item.filterText ?? item.label
            if text.hasPrefix(prefix) {
                ranked.append((0, item))
            } else if text.lowercased().hasPrefix(lowered) {
                ranked.append((1, item))
            } else if Self.startsAWord(inside: text, matching: lowered) {
                ranked.append((2, item))
            }
        }
        let order = ranked.sorted { a, b in a.rank != b.rank ? a.rank < b.rank : serverOrder(a.item, b.item) }
        return Array(order.prefix(limit).map(\.item))
    }

    /// The prefix begins a later word of the name: after an underscore, or at a capital that follows
    /// a small letter ("hasPrefix" for "pre"). Not in the middle of a word, where it is only noise.
    static func startsAWord(inside text: String, matching loweredPrefix: String) -> Bool {
        let original = Array(text.unicodeScalars)
        let lowered = Array(text.lowercased().unicodeScalars)
        let wanted = Array(loweredPrefix.unicodeScalars)
        guard original.count == lowered.count, original.count > 1, !wanted.isEmpty else { return false }
        for i in 1..<original.count where i + wanted.count <= lowered.count {
            let previous = original[i - 1], current = original[i]
            let humpAfterSmall = current.properties.isUppercase && !previous.properties.isUppercase && previous != "_"
                && (previous.properties.isLowercase || ("0"..."9").contains(previous))
            guard previous == "_" || humpAfterSmall else { continue }
            if Array(lowered[i..<(i + wanted.count)]) == wanted { return true }
        }
        return false
    }

    private static func serverOrder(_ a: CompletionItem, _ b: CompletionItem) -> Bool {
        (a.sortText ?? a.label) < (b.sortText ?? b.label)
    }

    // MARK: Inserting

    /// After "append(contentsOf: )" the caret belongs between the parentheses; after "uppercased()" after them.
    static func caretOffset(afterInserting text: String, for item: CompletionItem) -> Int {
        let length = text.utf16.count
        let callable = item.kind == .method || item.kind == .function || item.kind == .initializer
        if callable, text.hasSuffix(")"), !item.label.contains("()") { return length - 1 }
        return length
    }

    static func isWordUnit(_ unit: UInt16) -> Bool {
        (unit >= 0x30 && unit <= 0x39) || (unit >= 0x41 && unit <= 0x5A) || (unit >= 0x61 && unit <= 0x7A)
            || unit == 0x5F || unit > 0x7F
    }
}
