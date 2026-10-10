import AppKit
import EditorPlatformTextKit
import IDEApplication
import IDEDomain

/// What a language server gives besides completion, in one editor window: descriptions under the
/// pointer or at the caret, jumping to a definition, and problems drawn in the text and the margin.
/// It connects the controllers (IDEApplication) to the text view, the small window and the margin.
@MainActor
public final class LanguageFeaturesCoordinator: DefinitionNavigating {
    public typealias Provider = HoverProviding & DefinitionProviding & DiagnosticsProviding

    public let hover: HoverController
    public let definition: DefinitionController
    public let diagnostics: DiagnosticsController
    public let popup: HoverPopup
    /// Called after the problems of the document changed (the title bar shows their number).
    public var onDiagnosticsChange: (@MainActor () -> Void)?
    /// A definition is in another file: open it at that place.
    public var openLocation: (@MainActor (DefinitionLocation) -> Void)?
    /// A jump is about to leave the caret's place (its offset): the window remembers it for "Go Back".
    public var willJump: (@MainActor (Int) -> Void)?
    /// Lets the user choose among several definitions. By default a pop-up menu under the place.
    public var chooser: (@MainActor ([DefinitionLocation], Int, @escaping @MainActor (DefinitionLocation) -> Void) -> Void)?

    private let textView: NSTextView
    private let input: EditorInputHooks
    private let session: DocumentSession
    private var messageToken = 0
    private let diagnosticsPresenter: DiagnosticsPresenter

    public init(
        session: DocumentSession,
        editor: TextKitEditor,
        host: EditorHostView,
        lineIndex: DocumentLineIndex,
        provider: any Provider,
        clock: any DelayClock = SystemDelayClock(),
        dwell: Duration = .milliseconds(500)
    ) {
        self.session = session
        textView = editor.textView
        input = editor.input
        let textView = editor.textView
        let source = editor.backend
        popup = HoverPopup(textView: textView)
        diagnosticsPresenter = DiagnosticsPresenter(textView: textView)
        diagnostics = DiagnosticsController(session: session, provider: provider, presenter: diagnosticsPresenter)
        let diagnostics = diagnostics
        hover = HoverController(
            session: session,
            provider: provider,
            presenter: popup,
            clock: clock,
            dwell: dwell,
            wordAt: { offset in WordRange.around(offset, length: session.utf16Length, text: { source.substring(in: $0) }) },
            localMessages: { offset in diagnostics.marks(at: offset).map { "\(Self.word(for: $0.severity)): \($0.message)" } }
        )
        definition = DefinitionController(session: session, provider: provider)
        definition.navigator = self

        let hover = hover
        popup.onClose = { hover.dismiss() }
        input.pointerMoved = { offset in hover.pointerMoved(to: offset) }
        input.interactionBegan = { hover.dismiss() }
        input.requestHover = { [weak textView] in
            guard let range = textView?.selectedRange(), range.location != NSNotFound else { return }

            hover.requestAtCaret(range.location)
        }
        input.commandClick = { [weak self] offset in
            guard let self else { return false }

            Task { await self.definition.jump(from: offset) }

            return true
        }
        diagnostics.onChange = { [weak self, weak host] in
            host?.lineNumberRuler?.problemLines = diagnostics.severitiesByLine { lineIndex.current.line(containing: $0) }
            self?.onDiagnosticsChange?()
        }
    }

    isolated deinit {
        input.pointerMoved = nil
        input.interactionBegan = nil
        input.requestHover = nil
        input.commandClick = nil
        hover.dismiss()
    }

    // MARK: Commands

    /// Jump to Definition at the caret.
    public func jumpToDefinition() {
        let range = textView.selectedRange()
        guard range.location != NSNotFound else { return }

        Task { await definition.jump(from: range.location) }
    }

    /// Quick Help at the caret.
    public func showQuickHelp() {
        let range = textView.selectedRange()
        guard range.location != NSNotFound else { return }

        hover.requestAtCaret(range.location)
    }

    // MARK: DefinitionNavigating

    public func moveCaret(to offset: Int) {
        willJump?(textView.selectedRange().location)
        textView.setSelectedRange(NSRange(location: offset, length: 0))
        textView.scrollRangeToVisible(NSRange(location: offset, length: 0))
        textView.window?.makeFirstResponder(textView)
    }

    public func open(_ location: DefinitionLocation) {
        willJump?(textView.selectedRange().location)
        openLocation?(location)
    }

    public func choose(among places: [DefinitionLocation], near offset: Int, pick: @escaping @MainActor (DefinitionLocation) -> Void) {
        if let chooser { return chooser(places, offset, pick) }

        let menu = NSMenu(title: "Definitions")
        let picker = MenuPicker(pick: pick)
        for entry in Self.menuEntries(for: places) {
            let item = NSMenuItem(title: entry.title, action: #selector(MenuPicker.chosen(_:)), keyEquivalent: "")
            item.target = picker
            item.representedObject = entry.place
            menu.addItem(item)
        }
        let screen = textView.firstRect(forCharacterRange: NSRange(location: offset, length: 0), actualRange: nil)
        let point = textView.window.map { textView.convert($0.convertFromScreen(screen).origin, from: nil) } ?? .zero
        menu.popUp(positioning: nil, at: NSPoint(x: point.x, y: point.y + (textView.font?.pointSize ?? 12) * 1.6), in: textView)
        withExtendedLifetime(picker) {}
    }

    /// The lines of the menu: file and line, and where the file is.
    static func menuEntries(for places: [DefinitionLocation]) -> [(title: String, place: DefinitionLocation)] {
        places.map { place in
            let name = (place.path as NSString).lastPathComponent
            let folder = ((place.path as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath

            return ("\(name):\(place.line + 1)  —  \(folder)", place)
        }
    }

    /// A word of status under the place, for a moment.
    public func tell(_ message: String, at offset: Int) {
        messageToken += 1
        let mine = messageToken
        popup.show(message, anchor: UTF16TextRange(location: offset, length: 0))
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            if self?.messageToken == mine { self?.popup.dismiss() }
        }
    }

    static func word(for severity: DocumentDiagnostic.Severity) -> String {
        switch severity {
        case .error: "error"
        case .warning: "warning"
        case .information: "note"
        case .hint: "hint"
        }
    }
}

@MainActor
private final class MenuPicker: NSObject {
    let pick: @MainActor (DefinitionLocation) -> Void
    init(pick: @escaping @MainActor (DefinitionLocation) -> Void) { self.pick = pick }

    @objc func chosen(_ sender: NSMenuItem) {
        if let place = sender.representedObject as? DefinitionLocation { pick(place) }
    }
}
