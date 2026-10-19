import AppKit
import IDEApplication
import Testing
@testable import WorkspaceUI

@Suite(.serialized) @MainActor
struct CommandPaletteTests {
    private let commands = [
        PaletteCommand(id: "1", title: "Duplicate Line", group: "Edit", shortcut: "⌘D"),
        PaletteCommand(id: "2", title: "Toggle Line Comment", group: "Edit", shortcut: "⌘/"),
        PaletteCommand(id: "3", title: "Save", group: "File", shortcut: "⌘S", isEnabled: false)
    ]

    private func makePalette() -> (CommandPaletteViewController, NSWindow) {
        _ = NSApplication.shared
        let palette = CommandPaletteViewController()
        let window = NSWindow(contentViewController: palette)
        palette.present(commands)

        return (palette, window)
    }

    private func type(_ text: String, into palette: CommandPaletteViewController) {
        palette.search.stringValue = text
        palette.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: palette.search))
    }

    @Test func listsEveryCommandWithTheFirstSelectedAndFiltersWhileTyping() {
        let (palette, _) = makePalette()
        #expect(palette.results.map(\.id) == ["1", "2", "3"] && palette.selectedCommand?.id == "1")
        type("comm", into: palette)
        #expect(palette.results.map(\.id) == ["2"] && palette.selectedCommand?.id == "2")
        type("zzz", into: palette)
        #expect(palette.results.isEmpty && palette.selectedCommand == nil)
    }

    @Test func arrowsMoveWithinTheListAndReturnRunsTheSelectedCommand() {
        let (palette, _) = makePalette()
        var ran: [String] = []
        palette.run = { ran.append($0.id) }
        let field = NSTextView()
        _ = palette.control(palette.search, textView: field, doCommandBy: #selector(NSResponder.moveDown(_:)))
        #expect(palette.selectedCommand?.id == "2")
        _ = palette.control(palette.search, textView: field, doCommandBy: #selector(NSResponder.moveUp(_:)))
        _ = palette.control(palette.search, textView: field, doCommandBy: #selector(NSResponder.moveUp(_:)))
        #expect(palette.selectedCommand?.id == "1")
        #expect(palette.control(palette.search, textView: field, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        #expect(ran == ["1"])
    }

    @Test func aCommandThatCannotRunIsShownButNotRunAndEscapeCancels() {
        let (palette, _) = makePalette()
        var ran: [String] = []
        var cancelled = 0
        palette.run = { ran.append($0.id) }
        palette.cancel = { cancelled += 1 }
        let field = NSTextView()
        palette.move(by: 5)
        #expect(palette.selectedCommand?.id == "3")
        palette.runSelected()
        #expect(ran.isEmpty)
        _ = palette.control(palette.search, textView: field, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        #expect(cancelled == 1)
        #expect(!palette.control(
            palette.search,
            textView: field,
            doCommandBy: #selector(NSResponder.deleteBackward(_:))
        ))
    }

    @Test func presentingAgainStartsWithAnEmptyQuery() {
        let (palette, _) = makePalette()
        type("save", into: palette)
        palette.present(commands)
        #expect(palette.search.stringValue.isEmpty && palette.results.count == 3)
    }
}
