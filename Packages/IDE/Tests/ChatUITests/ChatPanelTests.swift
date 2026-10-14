import AppKit
import Foundation
import IDEApplication
import IDEDomain
import Testing
@testable import ChatUI

private actor ChatFixtureProvider: CodingAgentProvider {
    nonisolated let info = AgentProviderInfo(name: "Test demo", isDemo: true)
    var requests: [AgentRequest] = []
    private var streams: [UUID: AsyncThrowingStream<AgentEvent, Error>.Continuation] = [:]

    func events(for request: AgentRequest) async throws -> AsyncThrowingStream<AgentEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<AgentEvent, Error>.makeStream()
        requests.append(request)
        streams[request.id] = continuation

        return stream
    }

    func cancel(requestID: UUID) async { streams[requestID]?.finish() }

    func emit(_ event: AgentEvent, index: Int? = nil) {
        let index = index ?? requests.count - 1
        streams[requests[index].id]?.yield(event)
    }
}

@Suite(.serialized)
@MainActor
struct ChatPanelTests {
    private func wait(_ predicate: () async -> Bool) async throws {
        let end = ContinuousClock.now + .seconds(10)
        while !(await predicate()), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(2)) }
        try #require(await predicate())
    }

    private func host(_ panel: ChatPanelViewController, width: CGFloat = 420) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: -2000, y: -2000, width: width, height: 750),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = panel
        window.setContentSize(NSSize(width: width, height: 750))
        window.orderFront(nil)
        panel.view.layoutSubtreeIfNeeded()
        panel.renderNow()

        return window
    }

    @Test func completedResponseRemainsVisibleWhileTypingTheNextDraft() async throws {
        let provider = ChatFixtureProvider(), session = AgentSession(provider: provider)
        let panel = ChatPanelViewController(session: session), window = host(panel, width: 360)
        defer {
            panel.disconnect()
            session.stop()
            window.close()
        }
        window.makeFirstResponder(panel.input)
        panel.input.insertText("Show an example", replacementRange: NSRange(location: 0, length: 0))
        panel.submitMessage(nil)
        try await wait { await provider.requests.count == 1 }
        let block = UUID()
        await provider.emit(.textDelta(block: block, text: String(repeating: "Response paragraph.\n", count: 24)))
        await provider.emit(.finished)
        try await wait { session.state == .ready }
        try await Task.sleep(for: .milliseconds(100))
        for draft in ["", "Next", " question\nwith another line"] {
            panel.input.insertText(
                draft,
                replacementRange: NSRange(location: (panel.input.string as NSString).length, length: 0)
            )
            try await Task.sleep(for: .milliseconds(100))
            panel.view.layoutSubtreeIfNeeded()
            panel.view.displayIfNeeded()
            #expect(panel.table.numberOfRows == 2)
            let visible = panel.table.rows(in: panel.scroll.contentView.bounds)
            try #require(visible.location != NSNotFound && visible.length > 0)
            for index in visible.location..<NSMaxRange(visible) {
                let cell = try #require(
                    panel.table.view(atColumn: 0, row: index, makeIfNecessary: false) as? ChatMessageRow
                )
                #expect(cell.message?.id == session.messages[index].id)
                #expect(cell.window === window && cell.visibleRect.height > 0)
            }
            #expect(panel.followsLatest && panel.latest.isHidden)
        }
    }

    @Test func streamedTextKeepsItsNativeViewSelectionAndCopyReturnsExactUnicodeCode() async throws {
        let provider = ChatFixtureProvider(), session = AgentSession(provider: provider)
        let panel = ChatPanelViewController(session: session), window = host(panel)
        defer {
            panel.disconnect()
            session.stop()
            window.close()
        }
        window.makeFirstResponder(panel.input)
        panel.input.insertText("Show an example", replacementRange: NSRange(location: 0, length: 0))
        panel.submitMessage(nil)
        try await wait { await provider.requests.count == 1 }
        let textID = UUID(), codeID = UUID(), toolID = UUID()
        await provider.emit(.textDelta(block: textID, text: "first answer"))
        try await wait { session.messages.last?.blocks.count == 1 }
        panel.renderNow()
        let row = try #require(panel.table.view(atColumn: 0, row: 1, makeIfNecessary: true) as? ChatMessageRow)
        let text = try #require(row.textView(block: textID))
        #expect(text.textLayoutManager != nil)
        text.setSelectedRange(NSRange(location: 0, length: 5))
        let responder = window.firstResponder
        await provider.emit(.textDelta(block: textID, text: " with more content"))
        let code = "let emoji = \"👩‍💻🙂\"\n\nprint(emoji)\n"
        await provider.emit(.codeDelta(block: codeID, language: "swift", text: code))
        await provider.emit(.toolChanged(
            block: toolID,
            tool: .init(title: "Example activity", detail: "Simulated result. No files changed.", state: .succeeded)
        ))
        await provider.emit(.finished)
        try await wait { session.state == .ready }
        panel.renderNow()
        #expect(panel.table.view(atColumn: 0, row: 1, makeIfNecessary: true) === row)
        #expect(row.textView(block: textID) === text && text.selectedRange() == NSRange(location: 0, length: 5))
        #expect(text.string == "first answer with more content" && window.firstResponder === responder)
        var copied = ""
        panel.copyText = { copied = $0 }
        let codeView = try #require(row.blockView(id: codeID))
        codeView.copyCode(nil)
        #expect(copied == code && codeView.text.textLayoutManager != nil)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            window.appearance = NSAppearance(named: appearance)
            panel.view.layoutSubtreeIfNeeded()
            panel.view.displayIfNeeded()
            let bitmap = try #require(panel.view.bitmapImageRepForCachingDisplay(in: panel.view.bounds))
            panel.view.cacheDisplay(in: panel.view.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: "/private/tmp/swiftide-chat-\(name).png"))
        }
    }

    @Test func readerAnchorSurvivesStreamingAndResizeUntilLatestIsExplicitlySelected() async throws {
        let provider = ChatFixtureProvider(), session = AgentSession(provider: provider)
        let panel = ChatPanelViewController(session: session), window = host(panel, width: 360)
        defer {
            panel.disconnect()
            session.stop()
            window.close()
        }
        for i in 0..<20 {
            session.setDraft("Question \(i)\n" + String(repeating: "Read this earlier paragraph. ", count: 8))
            #expect(session.send())
            try await wait { await provider.requests.count == i + 1 }
            await provider.emit(.textDelta(
                block: UUID(),
                text: String(repeating: "Earlier response paragraph. ", count: 12)
            ))
            await provider.emit(.finished)
            try await wait { session.state == .ready }
        }
        panel.renderNow()
        session.setDraft("new response")
        #expect(session.send())
        try await wait { await provider.requests.count == 21 }
        panel.renderNow()
        let row = 10
        panel.scroll.contentView.scroll(to: NSPoint(x: 0, y: panel.table.rect(ofRow: row).minY + 7))
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: panel.scroll.contentView)
        #expect(!panel.followsLatest && !panel.latest.isHidden)
        let before = panel.scroll.contentView.bounds.minY - panel.table.rect(ofRow: row).minY
        await provider.emit(.textDelta(block: UUID(), text: String(repeating: "Growing response\n", count: 60)))
        try await wait { session.messages.last?.blocks.count == 1 }
        panel.renderNow()
        #expect(abs(panel.scroll.contentView.bounds.minY - panel.table.rect(ofRow: row).minY - before) < 2)
        window.setContentSize(NSSize(width: 480, height: 700))
        panel.view.layoutSubtreeIfNeeded()
        panel.renderNow()
        #expect(abs(panel.scroll.contentView.bounds.minY - panel.table.rect(ofRow: row).minY - before) < 2)
        #expect(!panel.followsLatest)
        panel.showLatest(nil)
        #expect(panel.followsLatest && panel.latest.isHidden)
        #expect(panel.table.bounds.height - panel.scroll.contentView.bounds.maxY < 2)
    }

    @Test func compositionBlocksSendAndReturnWhileShiftReturnKeepsAMultilineDraftWithUndo() async throws {
        let provider = ChatFixtureProvider(), session = AgentSession(provider: provider)
        let panel = ChatPanelViewController(session: session), window = host(panel)
        defer {
            panel.disconnect()
            session.stop()
            window.close()
        }
        window.makeFirstResponder(panel.input)
        panel.input.setMarkedText(
            "に",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: 0, length: 0)
        )
        #expect(panel.input.hasMarkedText() && !panel.send.isEnabled)
        panel.submitMessage(nil)
        #expect(session.messages.isEmpty)
        panel.input.keyDown(with: key(window, shift: false))
        #expect(session.messages.isEmpty)
        panel.input.unmarkText()
        panel.input.insertText(
            "draft",
            replacementRange: NSRange(location: 0, length: (panel.input.string as NSString).length)
        )
        panel.input.keyDown(with: key(window, shift: true))
        #expect(panel.input.string.contains("\n") && session.messages.isEmpty)
        panel.input.keyDown(with: key(window, shift: false))
        try await wait { await provider.requests.count == 1 }
        #expect(session.messages.count == 2 && panel.input.string.isEmpty)
        #expect(panel.input.undoManager?.canUndo == true)
        panel.input.undoManager?.undo()
        #expect(!panel.input.string.isEmpty && session.draft == panel.input.string)
        let recovered = panel.input.string
        panel.input.undoManager?.redo()
        #expect(panel.input.string.isEmpty && session.draft.isEmpty && session.messages.count == 2)
        panel.input.undoManager?.undo()
        #expect(panel.input.string == recovered && session.draft == recovered)
        session.cancel()
        try await wait { session.state == .ready }
        #expect(session.canSend)
    }

    @Test func coalescingAndDisconnectPreserveTheSessionWithoutLateViewUpdates() async throws {
        let provider = ChatFixtureProvider(), session = AgentSession(provider: provider)
        let panel = ChatPanelViewController(session: session), window = host(panel)
        defer {
            panel.disconnect()
            session.stop()
            window.close()
        }
        session.setDraft("burst")
        #expect(session.send())
        try await wait { await provider.requests.count == 1 }
        let count = panel.renderCount, block = UUID()
        for _ in 0..<100 { await provider.emit(.textDelta(block: block, text: "x")) }
        try await wait { session.messages.last?.plainText.count == 100 }
        try await Task.sleep(for: .milliseconds(50))
        #expect(panel.renderCount - count < 20)
        panel.disconnect()
        let disconnectedCount = panel.renderCount
        session.setDraft("next draft")
        await provider.emit(.finished)
        try await wait { session.state == .ready }
        try await Task.sleep(for: .milliseconds(50))
        #expect(panel.renderCount == disconnectedCount && session.draft == "next draft")
    }

    private func key(_ window: NSWindow, shift: Bool) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: shift ? .shift : [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: false,
            keyCode: 36
        )!
    }

    @Test func boundedHistoryEvictionAndToolFoldingKeepTheNativeTableConsistent() async throws {
        let provider = ChatFixtureProvider(), session = AgentSession(provider: provider)
        let panel = ChatPanelViewController(session: session), window = host(panel)
        defer {
            panel.disconnect()
            session.stop()
            window.close()
        }
        let tool = UUID()
        for i in 0..<103 {
            session.setDraft("Turn \(i)")
            #expect(session.send())
            try await wait { await provider.requests.count == i + 1 }
            await provider.emit(.toolChanged(
                block: tool,
                tool: .init(title: "Example", detail: "Details", state: .succeeded)
            ))
            await provider.emit(.finished)
            try await wait { session.state == .ready }
            panel.renderNow()
        }
        #expect(panel.table.numberOfRows == 200 && session.messages.first?.plainText == "Turn 3")
        let row = try #require(panel.table.view(atColumn: 0, row: 199, makeIfNecessary: true) as? ChatMessageRow)
        let block = try #require(row.blockView(id: tool))
        let height = panel.table.rect(ofRow: 199).height
        let earlierHeight = panel.table.rect(ofRow: 197).height
        row.toggleTool?(tool)
        #expect(block.text.isHidden && panel.table.rect(ofRow: 199).height < height)
        #expect(panel.table.rect(ofRow: 197).height == earlierHeight)
        row.toggleTool?(tool)
        #expect(!block.text.isHidden && panel.table.rect(ofRow: 199).height == height)
        session.clear()
        panel.renderNow()
        #expect(panel.table.numberOfRows == 0)
    }

    @Test func oversizedPasteIsRejectedWithoutLosingTheDraft() throws {
        let session = AgentSession(provider: ChatFixtureProvider())
        let panel = ChatPanelViewController(session: session), window = host(panel)
        defer {
            panel.disconnect()
            session.stop()
            window.close()
        }
        window.makeFirstResponder(panel.input)
        panel.input.insertText("keep", replacementRange: NSRange(location: 0, length: 0))
        panel.input.insertText(String(repeating: "🙂", count: 16_001), replacementRange: NSRange(location: 0, length: 4))
        #expect(panel.input.string == "keep" && session.draft == "keep")
        #expect(session.inputError == "Message limit: 64 KB.")
    }
}
