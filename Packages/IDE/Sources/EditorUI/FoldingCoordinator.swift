import AppKit
import EditorPlatformTextKit
import IDEApplication
import IDEDomain

/// What the foldable parts of a document are made of.
public enum FoldStyle: Equatable, Sendable {
    /// Blocks between `{` and `}`, and block comments; `characterLiterals` for the C family.
    case braces(characterLiterals: Bool)
    /// The sections under headings and the fenced code blocks of Markdown.
    case markdown
    /// JSON: braces and brackets.
    case json
    case xml
    case yaml
    /// TOML: the tables.
    case toml
    case shell
    /// Files of settings: braces and parentheses (project files), `[sections]` (ini).
    case config
}

extension DocumentLanguage {
    /// How the blocks of the language are found, if it has any.
    public var foldStyle: FoldStyle? {
        switch self {
        case .swift, .c, .cpp, .objectiveC, .objectiveCPP: .braces(characterLiterals: isCFamily)
        case .metal: .braces(characterLiterals: true)
        case .markdown: .markdown
        case .json: .json
        case .xml: .xml
        case .yaml: .yaml
        case .toml: .toml
        case .shell: .shell
        case .config: .config
        case .plainText: nil
        }
    }
}

/// Code folding for one document: finds what can be folded, keeps folds right while the text is
/// edited, leaves folded lines out of the layout, and shows the arrows in the line-number margin.
/// The text, its versions, Undo and the language server never see a fold.
@MainActor
public final class FoldingCoordinator {
    /// Documents larger than this (UTF-16 units) are not scanned for regions.
    public static let sizeLimit = 1_500_000

    public let model = FoldModel()

    private let session: DocumentSession
    private let editor: TextKitEditor
    private weak var ruler: LineNumberRulerView?
    private let lineIndex: DocumentLineIndex
    private let isEnabled: () -> Bool
    private let style: () -> FoldStyle
    private var changeSubscription: UUID?
    private var selectionObserver: NSObjectProtocol?
    private var pending: Task<Void, Never>?
    private let delay: Duration
    private var isStopped = false

    public init(
        session: DocumentSession,
        editor: TextKitEditor,
        ruler: LineNumberRulerView?,
        lineIndex: DocumentLineIndex,
        isEnabled: @escaping () -> Bool,
        style: @escaping () -> FoldStyle,
        delay: Duration = .milliseconds(150)
    ) {
        self.session = session
        self.editor = editor
        self.ruler = ruler
        self.lineIndex = lineIndex
        self.isEnabled = isEnabled
        self.style = style
        self.delay = delay
        ruler?.showsFolding = true
        ruler?.onToggleFold = { [weak self] line in self?.toggle(line: line) }
        model.onChange = { [weak self] in self?.modelChanged() }
        changeSubscription = session.subscribeToChanges { [weak self] changes in
            guard let self else { return }

            // Hidden ranges follow the text at once; what can be folded is read again soon.
            model.apply(changes.edits)
            scheduleRefresh()
        }
        selectionObserver = NotificationCenter.default.addObserver(
            forName: NSTextView.didChangeSelectionNotification,
            object: editor.textView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.selectionChanged() }
        }
        refresh()
    }

    isolated deinit { stop() }

    public func stop() {
        guard !isStopped else { return }

        isStopped = true
        pending?.cancel()
        pending = nil
        if let changeSubscription { session.unsubscribeFromChanges(changeSubscription) }
        changeSubscription = nil
        if let selectionObserver { NotificationCenter.default.removeObserver(selectionObserver) }
        selectionObserver = nil
        model.onChange = nil
        editor.backend.setHiddenRanges([])
        editor.textView.setFoldPlaceholders([]) { _ in }
        ruler?.onToggleFold = nil
    }

    /// Reads what can be folded from the text now: at the start, after a change of language.
    public func refresh() {
        pending?.cancel()
        pending = nil
        guard !isStopped else { return }

        guard isEnabled(), session.utf16Length <= Self.sizeLimit else {
            model.update(regions: [])

            return
        }

        let text = Array(editor.backend.text.utf16)
        switch style() {
        case .braces(let characterLiterals):
            model.update(regions: FoldRegions.compute(in: text, characterLiterals: characterLiterals))
        case .markdown: model.update(regions: FoldRegions.computeMarkdown(in: text))
        case .json: model.update(regions: FoldRegions.compute(in: text, pairs: [.braces, .brackets]))
        case .xml: model.update(regions: FoldRegions.computeXML(in: text))
        case .yaml: model.update(regions: FoldRegions.computeYAML(in: text))
        case .toml: model.update(regions: FoldRegions.computeSections(in: text))
        case .shell: model.update(regions: FoldRegions.computeShell(in: text))
        case .config:
            let blocks = FoldRegions.compute(in: text, pairs: [.braces, .parentheses], hashComments: true)
            let sections = FoldRegions.computeSections(in: text)
            let taken = Set(blocks.map(\.startLine))
            model.update(regions: (blocks + sections.filter { !taken.contains($0.startLine) }).sorted {
                $0.startLine < $1.startLine
            })
        }
    }

    private func scheduleRefresh() {
        pending?.cancel()
        pending = Task { [weak self, delay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }

            self?.refresh()
        }
    }

    // MARK: Commands

    public func toggle(line: Int) {
        model.toggle(startLine: line)
    }

    /// Folds the innermost region around the caret that is not folded yet; if the caret's own
    /// line starts a folded region, nothing more is folded.
    public func foldAtCaret() {
        let line = caretLine()
        var candidates = model.regions.filter { $0.startLine <= line && line <= $0.endLine }
        candidates.sort { $0.startLine > $1.startLine }
        if let region = candidates.first(where: { !model.isFolded(startLine: $0.startLine) }) {
            model.fold(startLine: region.startLine)
        }
    }

    /// Opens the fold on the caret's line, or the innermost fold around it.
    public func unfoldAtCaret() {
        let line = caretLine()
        if model.unfold(startLine: line) { return }

        let around = model.regions.filter { $0.startLine < line && line <= $0.endLine }
            .sorted { $0.startLine > $1.startLine }
        if let region = around.first(where: { model.isFolded(startLine: $0.startLine) }) {
            model.unfold(startLine: region.startLine)
        }
    }

    public func unfoldAll() { model.unfoldAll() }

    /// Folds every region, outermost first, so a fold hides its inner ones.
    public func foldAll() {
        for region in model.regions { model.fold(startLine: region.startLine) }
    }

    private func caretLine() -> Int {
        lineIndex.current.line(containing: editor.textView.selectedRange().location)
    }

    // MARK: Showing it

    private func modelChanged() {
        guard !isStopped else { return }

        let hidden = model.hiddenRanges
        // A caret or selection inside text that is about to disappear goes to the end of its header.
        let selection = editor.textView.selectedRange()
        for fold in model.folded where fold.hidden.contains(selection.location)
            || (selection.length > 0 && selection.location < fold.hidden.upperBound
                && NSMaxRange(selection) > fold.hidden.lowerBound) {
            editor.textView.setSelectedRange(NSRange(
                location: max(fold.headerStart, fold.hidden.lowerBound - 1),
                length: 0
            ))
            break
        }

        editor.backend.setHiddenRanges(hidden.map { NSRange(location: $0.lowerBound, length: $0.count) })
        // The box after each header line stands where that line's text ends, before its terminator.
        let ends = model.folded.map { headerEnd(before: $0.hidden.lowerBound) }
        editor.textView.setFoldPlaceholders(ends) { [weak self] offset in self?.openFold(endingAt: offset) }
        var marks: [Int: Bool] = [:]
        for region in model.regions { marks[region.startLine] = model.isFolded(startLine: region.startLine) }
        ruler?.foldMarks = marks
        editor.textView.needsDisplay = true
    }

    /// The end of the line that is followed by text starting at `start`: before its `\n`, `\r\n` or `\r`.
    private func headerEnd(before start: Int) -> Int {
        let text = editor.backend.text as NSString
        guard start > 0, start <= text.length else { return max(0, start - 1) }

        var end = start - 1
        if end > 0, text.character(at: end) == 0x0A, text.character(at: end - 1) == 0x0D { end -= 1 }

        return end
    }

    private func openFold(endingAt offset: Int) {
        guard let fold = model.folded.first(where: { headerEnd(before: $0.hidden.lowerBound) == offset }),
              let region = model.regions.first(where: { $0.headerStart == fold.headerStart }) else { return }

        model.unfold(startLine: region.startLine)
    }

    /// Going into folded text (a search hit, a jump to a line, a click on an error) opens it.
    private func selectionChanged() {
        guard !isStopped, !model.folded.isEmpty else { return }

        let selection = editor.textView.selectedRange()
        if model.unfoldHiding(offset: selection.location) { return }

        if selection.length > 0 { _ = model.unfoldHiding(offset: NSMaxRange(selection) - 1) }
    }
}
