import AppKit
import Testing
@testable import WorkspaceUI

@Suite(.serialized)
@MainActor
struct WorkspaceNotificationTests {
    @Test func collectionCoalescesAndBoundsCardsAndReleasesDismissedActions() {
        let notifications = WorkspaceNotifications(capacity: 2)
        var changes = 0
        let subscription = notifications.subscribe { changes += 1 }
        notifications.post(.init(id: "a", title: "First"))
        notifications.post(.init(id: "b", title: "Second"))
        notifications.post(.init(id: "a", kind: .warning, title: "Updated"))
        #expect(notifications.items.map(\.id) == ["a", "b"])
        #expect(notifications.items[0].title == "Updated")
        notifications.post(.init(id: "c", title: "Third"))
        #expect(notifications.items.map(\.id) == ["b", "c"])
        notifications.dismiss("b")
        notifications.dismiss("missing")
        #expect(changes == 5 && notifications.items.map(\.id) == ["c"])
        notifications.unsubscribe(subscription)
        notifications.removeAll()
        #expect(changes == 5 && notifications.items.isEmpty)
        weak var retained: NotificationLifetimeProbe?
        do {
            let probe = NotificationLifetimeProbe()
            retained = probe
            notifications.post(.init(id: "owned", title: "Owned", actions: [.init(title: "Run", perform: {
                _ = probe
            })]))
        }
        #expect(retained != nil)
        notifications.dismiss("owned")
        #expect(retained == nil)
    }

    @Test func cardsPassClicksThroughPreserveEditorAndRunOnlyExplicitActions() throws {
        _ = NSApplication.shared
        let editor = NSTextView()
        editor.string = "Original document"
        editor.setSelectedRange(NSRange(location: 3, length: 2))
        let shell = WorkspaceShellViewController(
            state: .init(),
            editor: editor,
            editorFocus: editor,
            panels: [:],
            project: "A",
            path: "/a"
        )
        let window = makeWindow(shell)
        defer {
            shell.disconnect()
            window.close()
        }
        window.makeFirstResponder(editor)
        let focus = window.firstResponder
        var invoked = 0
        shell.notifications.post(.init(
            id: "result",
            kind: .success,
            title: "Operation completed",
            message: "Details",
            actions: [.init(title: "Inspect", perform: {
                invoked += 1
            })]
        ))
        shell.view.layoutSubtreeIfNeeded()
        let overlay = try #require(shell.notificationOverlay)
        let card = try #require(overlay.cards.first)
        #expect(window.firstResponder === focus && invoked == 0)
        #expect(editor.string == "Original document" && editor.selectedRange() == NSRange(location: 3, length: 2))
        let outside = overlay.convert(NSPoint(x: 10, y: overlay.bounds.height - 10), to: overlay.superview)
        #expect(overlay.hitTest(outside) == nil)
        let centre = card.convert(NSPoint(x: card.bounds.midX, y: card.bounds.midY), to: overlay.superview)
        #expect(overlay.hitTest(centre) != nil)
        let button = try #require(card.actionButtons.first)
        button.performClick(nil)
        #expect(invoked == 1)
        shell.notifications.post(.init(
            id: "result",
            kind: .warning,
            title: "Updated result",
            actions: [.init(title: "Inspect again", perform: {
                invoked += 10
            })]
        ))
        #expect(overlay.cards.first === card && card.actionButtons.first === button)
        button.performClick(nil)
        #expect(invoked == 11)
        card.close.performClick(nil)
        shell.view.layoutSubtreeIfNeeded()
        #expect(shell.notifications.items.isEmpty && overlay.cards.isEmpty && overlay.scroll.isHidden)
        #expect(window.firstResponder === focus && editor.string == "Original document")
        shell.disconnect()
        shell.notifications.post(.init(title: "Disconnected"))
        #expect(overlay.cards.isEmpty)
    }

    @Test func stackFitsCentralContentAndScrollsLongMessagesInBothAppearances() throws {
        _ = NSApplication.shared
        let state = WorkspaceLayoutState(available: Set(WorkspaceTool.allCases))
        let shell = WorkspaceShellViewController(
            state: state,
            editor: NSView(),
            panels: [
                .files: .init(view: NSView()),
                .assistant: .init(view: NSView()),
                .terminal: .init(view: NSView())
            ],
            project: "Preview",
            path: "/preview"
        )
        let window = makeWindow(shell)
        defer {
            shell.disconnect()
            window.close()
        }
        shell.notifications.post(.init(
            kind: .warning,
            title: "Workspace Preview",
            message: "A warning with a longer explanation that wraps across lines.",
            actions: [.init(title: "Show details…", perform: {})]
        ))
        shell.notifications.post(.init(
            title: "34 files committed · sample",
            message: "git merge, git rebase",
            actions: [.init(title: "View commit…", perform: {})]
        ))
        var colours: [CGFloat] = []
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            window.appearance = NSAppearance(named: appearance)
            shell.view.layoutSubtreeIfNeeded()
            let overlay = try #require(shell.notificationOverlay)
            #expect(overlay.scroll.frame.width > 300 && overlay.scroll.frame.height > 100)
            #expect(overlay.bounds.contains(overlay.scroll.frame))
            #expect(overlay.cards.count == 2)
            let first = overlay.cards[0]
            #expect(first.frame.height > 60 && overlay.cards[1].frame.height > 60)
            #expect(first.message.frame.height >= 25, "body wraps instead of clipping")
            shell.view.displayIfNeeded()
            let bitmap = try #require(first.bitmapImageRepForCachingDisplay(in: first.bounds))
            first.cacheDisplay(in: first.bounds, to: bitmap)
            let colour = try #require(bitmap.colorAt(x: 3, y: 3)?.usingColorSpace(.deviceRGB))
            colours.append(colour.redComponent)
            let info = overlay.cards[1]
            let icon = try #require(info.subviews.compactMap { $0 as? NSImageView }.first)
            let iconBitmap = try #require(icon.bitmapImageRepForCachingDisplay(in: icon.bounds))
            icon.cacheDisplay(in: icon.bounds, to: iconBitmap)
            let bluePixels = (0..<iconBitmap.pixelsHigh).reduce(0) { total, y in
                total + (0..<iconBitmap.pixelsWide).filter { x in
                    guard let pixel = iconBitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }

                    return pixel.alphaComponent > 0.5 && pixel.blueComponent > pixel.redComponent + 0.15
                }.count
            }
            #expect(bluePixels > 8, "information icon is visible on the first render in either appearance")
            if ProcessInfo.processInfo.environment["SWIFTIDE_RENDER_NOTIFICATIONS"] == "1" {
                let rendered = try #require(shell.view.bitmapImageRepForCachingDisplay(in: shell.view.bounds))
                shell.view.cacheDisplay(in: shell.view.bounds, to: rendered)
                try #require(rendered.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: "/private/tmp/swiftide-notifications-\(name).png"))
            }
        }
        #expect(colours[0] > colours[1] + 0.4)
        shell.select(.assistant)
        shell.select(.terminal)
        window.setContentSize(NSSize(width: 900, height: 560))
        for n in 0..<3 {
            shell.notifications.post(.init(
                id: "long\(n)",
                kind: .error,
                title: "Long message \(n)",
                message: String(repeating: "A detailed failure with context. ", count: 80)
            ))
        }
        shell.view.layoutSubtreeIfNeeded()
        let overlay = try #require(shell.notificationOverlay)
        #expect(overlay.bounds.contains(overlay.scroll.frame))
        #expect(overlay.scroll.frame.width <= overlay.bounds.width - 23)
        #expect(overlay.scroll.frame.height <= overlay.bounds.height * 0.5 + 1)
        #expect(try #require(overlay.scroll.documentView).frame.height > overlay.scroll.contentView.bounds.height)
        let last = try #require(overlay.cards.last)
        let top = try #require(overlay.scroll.documentView).convert(last.bounds, from: last).minY
        #expect(
            abs(overlay.scroll.contentView.bounds.minY - top) < 2,
            "a long new card reveals its heading and close button"
        )
        shell.toggleFocusEditor(nil)
        shell.view.layoutSubtreeIfNeeded()
        #expect(overlay.cards.count == 5 && overlay.bounds.contains(overlay.scroll.frame))
    }

    private func makeWindow(_ shell: WorkspaceShellViewController) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: -2000, y: -2000, width: 1280, height: 820),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = shell

        return window
    }
}

private final class NotificationLifetimeProbe {}
