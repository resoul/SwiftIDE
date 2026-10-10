import AppKit
import Testing
@testable import SwiftIDE

struct WorkspacePreviewTests {
    @Test func toolsToggleIndependentlyByZone() {
        var layout = WorkspacePreviewLayout()
        layout.toggle(.assistant)
        layout.toggle(.terminal)
        layout.toggle(.search)
        #expect(layout.left == .search)
        #expect(layout.right == .assistant)
        #expect(layout.bottom == .terminal)
        layout.toggle(.search)
        #expect(layout.left == nil)
        #expect(layout.right == .assistant)
        layout.toggle(.build)
        #expect(layout.bottom == .build)
    }

    @Test func savedLayoutKeepsDimensionsAndHiddenPanels() throws {
        var layout = WorkspacePreviewLayout()
        layout.left = nil
        layout.right = .inspector
        layout.bottom = .problems
        layout.leftWidth = 310
        layout.rightWidth = 280
        layout.bottomHeight = 170
        let decoded = try JSONDecoder().decode(WorkspacePreviewLayout.self, from: JSONEncoder().encode(layout))
        #expect(decoded == layout)
    }

    @Test @MainActor func focusModeRestoresPanelsAndResizedDividers() throws {
        _ = NSApplication.shared
        let defaults = try #require(UserDefaults(suiteName: "SwiftIDEPreviewTests.\(UUID().uuidString)"))
        let controller = WorkspacePreviewWindowController(preferences: defaults)
        let content = try #require(controller.window?.contentView)
        controller.showPreviewAssistant(nil)
        controller.showPreviewTerminal(nil)
        content.layoutSubtreeIfNeeded()
        let splitViews = descendants(content).compactMap { $0 as? NSSplitView }
        let horizontal = try #require(splitViews.first { $0.isVertical })
        let vertical = try #require(splitViews.first { !$0.isVertical })
        horizontal.setPosition(250, ofDividerAt: 0)
        vertical.setPosition(vertical.bounds.height - 210, ofDividerAt: 0)
        content.layoutSubtreeIfNeeded()
        let leftWidth = horizontal.subviews[0].frame.width
        let bottomHeight = vertical.subviews[1].frame.height
        controller.toggleFocusEditor(nil)
        #expect(horizontal.isSubviewCollapsed(horizontal.subviews[0]))
        #expect(vertical.isSubviewCollapsed(vertical.subviews[1]))
        controller.toggleFocusEditor(nil)
        content.layoutSubtreeIfNeeded()
        #expect(!horizontal.isSubviewCollapsed(horizontal.subviews[0]))
        #expect(!horizontal.isSubviewCollapsed(horizontal.subviews[2]))
        #expect(!vertical.isSubviewCollapsed(vertical.subviews[1]))
        #expect(abs(horizontal.subviews[0].frame.width - leftWidth) < 2)
        #expect(abs(vertical.subviews[1].frame.height - bottomHeight) < 2)
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        let saved = try #require(defaults.data(forKey: "workspacePreview.layout.v1"))
        let layout = try JSONDecoder().decode(WorkspacePreviewLayout.self, from: saved)
        #expect(layout.right == .assistant)
        #expect(layout.bottom == .terminal)
        controller.resetWorkspaceLayout(nil)
        #expect(horizontal.isSubviewCollapsed(horizontal.subviews[2]))
        #expect(vertical.isSubviewCollapsed(vertical.subviews[1]))
    }

    @MainActor private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }
}
