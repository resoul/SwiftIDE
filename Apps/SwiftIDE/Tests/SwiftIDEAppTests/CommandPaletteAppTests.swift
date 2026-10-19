import AppKit
import IDEApplication
import WorkspaceUI
import Testing
@testable import SwiftIDE

extension NativeAppTests {
    @Suite(.serialized)
    @MainActor
    struct CommandPaletteAppTests {
        private static let opener = #selector(AppDelegate.showCommandPalette(_:))

        private func menu() -> NSMenu {
            let main = NSMenu()
            let edit = NSMenu(title: "Edit")
            let open = NSMenuItem(title: "Command Palette…", action: Self.opener, keyEquivalent: "P")
            let duplicate = NSMenuItem(title: "Duplicate Line", action: #selector(NSText.copy(_:)), keyEquivalent: "d")
            let complete = NSMenuItem(title: "Complete", action: #selector(NSText.paste(_:)), keyEquivalent: " ")
            complete.keyEquivalentModifierMask = .control
            let hidden = NSMenuItem(title: "Hidden", action: #selector(NSText.cut(_:)), keyEquivalent: "")
            hidden.isHidden = true
            for item in [
                open,
                .separator(),
                duplicate,
                complete,
                hidden,
                NSMenuItem(title: "Plain", action: nil, keyEquivalent: "")
            ] {
                edit.addItem(item)
            }

            let parent = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
            parent.submenu = edit
            main.addItem(parent)

            return main
        }

        @Test func theMenuIsTheListOfCommandsWithItsPathShortcutAndAvailability() {
            let catalog = MenuCommandCatalog(isAvailable: { $0.title != "Complete" })
            let entries = catalog.entries(in: menu(), excluding: Self.opener)
            #expect(entries.map(\.command.title) == ["Duplicate Line", "Complete"])
            #expect(entries.map(\.command.group) == ["Edit", "Edit"])
            #expect(entries.map(\.command.shortcut) == ["⌘D", "⌃Space"])
            #expect(entries.map(\.command.isEnabled) == [true, false])
            #expect(Set(entries.map(\.command.id)).count == 2)
        }

        @Test func aCapitalLetterShowsShiftAndTheOpenerListsItself() {
            let all = MenuCommandCatalog(isAvailable: { _ in true }).entries(in: menu())
            #expect(all.first?.command.title == "Command Palette…" && all.first?.command.shortcut == "⇧⌘P")
        }

        @Test func choosingACommandClosesThePaletteAndPerformsThatMenuItemOnce() async throws {
            let main = menu()
            var performed: [String] = []
            let palette = CommandPaletteController(
                catalog: MenuCommandCatalog(isAvailable: { _ in true }),
                opener: Self.opener,
                menu: { main },
                perform: { performed.append($0.title) }
            )
            palette.show(over: nil)
            #expect(palette.isShown)
            let window = try #require(NSApp.windows.first { $0.accessibilityLabel() == "Command Palette" })
            let content = try #require(window.contentViewController as? CommandPaletteViewController)
            let chosen = try #require(content.selectedCommand)
            content.run?(chosen)
            #expect(!palette.isShown)
            for _ in 0..<200 where performed.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
            #expect(performed == ["Duplicate Line"])
        }
    }
}
