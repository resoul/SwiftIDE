import AppKit
import IDEApplication
import IDEDomain
import Testing
@testable import WorkspaceUI

@Suite(.serialized) @MainActor
struct EditorAreaTests {
    private func settle() async throws { try await Task.sleep(for: .milliseconds(30)) }

    @Test func nativeTabSelectionCloseAndLocalDragUseStableDocumentIDs() async throws {
        _ = NSApplication.shared
        let area = EditorAreaViewController()
        let tabs = DocumentTabs()
        let a = DocumentID(), b = DocumentID(), c = DocumentID()
        for id in [a, b, c] { tabs.open(id) }
        let presentations = [
            DocumentTabPresentation(
                id: a,
                name: "a.swift",
                path: "/w/a.swift",
                decoration: .init(exclusionReason: "Excluded", isUnsaved: true)
            ),
            DocumentTabPresentation(id: b, name: "b.swift", path: "/w/b.swift"),
            DocumentTabPresentation(id: c, name: "c.swift", path: "/w/c.swift")
        ]
        let window = NSWindow(
            contentRect: NSRect(x: -2000, y: -2000, width: 700, height: 450),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = area
        window.setContentSize(NSSize(width: 700, height: 450))
        defer { window.close() }

        func render() {
            area.tabs.present(
                tabs.order.compactMap { id in presentations.first { $0.id == id } },
                selected: tabs.selected
            )
        }

        area.tabs.onSelect = {
            tabs.select($0)
            render()
        }
        area.tabs.onClose = {
            tabs.remove($0)
            render()
        }
        area.tabs.onMove = {
            tabs.move($0, to: $1)
            render()
        }
        render()
        window.contentView?.layoutSubtreeIfNeeded()
        try await settle()
        area.tabs.collectionView(area.tabs.collection, didSelectItemsAt: [IndexPath(item: 0, section: 0)])
        #expect(tabs.selected == a)
        try await settle()
        let cell = try #require(area.tabs.collection.item(at: IndexPath(item: 0, section: 0)))
        #expect(cell.view.toolTip?.contains("Unsaved editor changes") == true)
        #expect(cell.view.toolTip?.contains("Excluded") == true)

        // Only the active tab has a close button.
        func closeButton(_ index: Int) throws -> NSButton {
            let cell = try #require(area.tabs.collection.item(at: IndexPath(item: index, section: 0)))

            return try #require(cell.view.subviews.compactMap { $0 as? NSStackView }.first?.arrangedSubviews
                .last as? NSButton)
        }

        #expect(try !closeButton(0).isHidden)
        #expect(try closeButton(1).isHidden && closeButton(2).isHidden)
        area.tabs.collectionView(area.tabs.collection, didSelectItemsAt: [IndexPath(item: 1, section: 0)])
        try await settle()
        #expect(try closeButton(0).isHidden && !closeButton(1).isHidden && closeButton(2).isHidden)

        // An inactive tab shows its close button while the pointer is over it.
        func pointer(_ type: NSEvent.EventType, over index: Int) throws {
            let cell = try #require(area.tabs.collection.item(at: IndexPath(item: index, section: 0)))
            let event = try #require(NSEvent.enterExitEvent(
                with: type,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                trackingNumber: 0,
                userData: nil
            ))
            if type == .mouseEntered { cell.view.mouseEntered(with: event) } else { cell.view.mouseExited(with: event) }
        }

        try pointer(.mouseEntered, over: 2)
        #expect(try closeButton(0).isHidden && !closeButton(1).isHidden && !closeButton(2).isHidden)

        func pixels(_ index: Int) throws -> Data {
            let view = try #require(area.tabs.collection.item(at: IndexPath(item: index, section: 0))).view
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)

            return try #require(bitmap.representation(using: .png, properties: [:]))
        }

        // The hovered inactive tab has a background; the others, and the tab once left, do not.
        let hoveredPixels = try pixels(2)
        try pointer(.mouseExited, over: 2)
        let leftPixels = try pixels(2)
        #expect(hoveredPixels != leftPixels, "the hover background is drawn and goes away")
        #expect(try closeButton(0).isHidden && !closeButton(1).isHidden && closeButton(2).isHidden)
        try pointer(.mouseEntered, over: 1)
        try pointer(.mouseExited, over: 1)
        #expect(try !closeButton(1).isHidden, "the active tab keeps its button")
        area.tabs.collectionView(area.tabs.collection, didSelectItemsAt: [IndexPath(item: 0, section: 0)])
        try await settle()
        let pasteboard = NSPasteboard(name: .init("SwiftIDE-tabs-test-\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        let writer = try #require(area.tabs.collectionView(
            area.tabs.collection,
            pasteboardWriterForItemAt: IndexPath(item: 0, section: 0)
        ))
        pasteboard.writeObjects([writer])
        #expect(area.tabs.moveTab(from: area.tabs.collection, pasteboard: pasteboard, to: 3))
        #expect(tabs.order == [b, c, a] && tabs.selected == a)
        let foreign = DocumentTabBarViewController()
        _ = foreign.view
        foreign.present(presentations, selected: a)
        try await settle()
        #expect(!area.tabs.moveTab(from: foreign.collection, pasteboard: pasteboard, to: 0))
        #expect(!foreign.moveTab(from: foreign.collection, pasteboard: pasteboard, to: 0))
        #expect(!area.tabs.moveTab(from: area.tabs.collection, pasteboard: pasteboard, to: 4))
        // Use the native close button after a queued reorder, rather than calling the callback directly.
        window.contentView?.layoutSubtreeIfNeeded()
        try await settle()
        let movedCell = try #require(area.tabs.collection.item(at: IndexPath(item: 2, section: 0)))
        let close = try #require(movedCell.view.subviews.compactMap { $0 as? NSStackView }.first?.arrangedSubviews
            .last as? NSButton)
        close.performClick(nil)
        #expect(tabs.order == [b, c] && tabs.selected == c)
    }

    @Test func overflowingStripKeepsTheSelectedTabVisibleAndEditorFocusUntouched() async throws {
        _ = NSApplication.shared
        let area = EditorAreaViewController()
        let document = NSViewController()
        let text = NSTextView()
        document.view = text
        area.show(document, focusTarget: text)
        let window = NSWindow(
            contentRect: NSRect(x: -2000, y: -2000, width: 450, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = area
        window.setContentSize(NSSize(width: 450, height: 300))
        defer { window.close() }
        window.makeFirstResponder(text)
        let responder = window.firstResponder
        let items = (0..<12).map {
            DocumentTabPresentation(id: DocumentID(), name: "LongDocumentName-\($0).swift", path: "/w/\($0).swift")
        }
        let selected = try #require(items.last?.id)
        area.tabs.present(items, selected: selected)
        window.contentView?.layoutSubtreeIfNeeded()
        try await settle()
        #expect(area.tabs.collection.visibleRect.minX > 0)
        #expect(area.tabs.collection.item(at: IndexPath(item: 11, section: 0)) != nil)
        #expect(window.firstResponder === responder)
        var changed = items
        changed[11] = .init(
            id: selected,
            name: "renamed.swift",
            path: "/w/renamed.swift",
            decoration: .init(isUnsaved: true)
        )
        area.tabs.present(changed, selected: selected)
        try await settle()
        #expect(area.tabs.selected == selected && window.firstResponder === responder)
    }

    @Test func switchingViewsAndEmptyContentRetainsOriginalEditorState() throws {
        let area = EditorAreaViewController()
        let first = NSViewController(), second = NSViewController()
        let editor = NSTextView()
        editor.string = "original text"
        editor.setSelectedRange(NSRange(location: 2, length: 3))
        first.view = editor
        second.view = NSTextView()
        area.show(first, focusTarget: editor)
        area.show(second, focusTarget: second.view)
        #expect(first.parent == nil && editor.string == "original text")
        area.show(first, focusTarget: editor)
        #expect(area.active === first && area.focusTarget === editor)
        #expect(editor.selectedRange() == NSRange(location: 2, length: 3))
        area.show(nil)
        #expect(area.active == nil && area.focusTarget == nil && editor.superview == nil)
    }

    @Test func registeredArbitraryPanelRestoresDraftAndFocusLayoutWithoutAnEnumCase() throws {
        _ = NSApplication.shared
        let tool = WorkspaceTool(id: 100, title: "Containers", symbol: "shippingbox", zone: .right)
        let draft = NSTextField(string: "container filter")
        let state = WorkspaceLayoutState(available: [.files, tool])
        let shell = WorkspaceShellViewController(
            state: state,
            editor: NSView(),
            panels: [.files: .init(view: NSView()), tool: .init(view: draft, focusTarget: draft)],
            project: "Project",
            path: "/w"
        )
        let window = NSWindow(
            contentRect: NSRect(x: -2000, y: -2000, width: 1280, height: 820),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = shell
        defer {
            shell.disconnect()
            window.close()
        }
        shell.select(tool)
        #expect(shell.buttons[tool]?.isEnabled == true && state.layout.right == tool)
        state.resize(right: 350)
        let saved = state.persistentLayout
        shell.toggleFocusEditor(nil)
        #expect(state.layout.left == nil && state.layout.right == nil)
        shell.toggleFocusEditor(nil)
        #expect(state.layout == saved && draft.stringValue == "container filter")
        #expect(draft.isDescendant(of: shell.view))
        let decoded = try JSONDecoder().decode(WorkspaceLayout.self, from: JSONEncoder().encode(saved))
        #expect(decoded == saved)
        let old = try JSONDecoder().decode(WorkspaceTool.self, from: Data("6".utf8))
        #expect(old == .assistant)
        #expect(try String(decoding: JSONEncoder().encode(WorkspaceTool.files), as: UTF8.self) == "0")
        let removed = WorkspaceLayoutState(layout: decoded, available: [.files])
        #expect(removed.layout.right == nil)
    }
}

@Suite(.serialized) @MainActor
struct ScrollElasticityTests {
    @Test func panelScrollViewsStopAtTheirEnds() {
        _ = NSApplication.shared
        let scroll = NSScrollView.nonElastic()
        #expect(scroll.verticalScrollElasticity == .none && scroll.horizontalScrollElasticity == .none)
    }
}
