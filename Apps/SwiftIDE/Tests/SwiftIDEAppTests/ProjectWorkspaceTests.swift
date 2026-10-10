import AppKit
import IDEApplication
import IDETestSupport
import Testing
import WorkspaceUI
@testable import SwiftIDE

extension NativeAppTests {
    @Suite(.serialized)
    @MainActor
    struct ProjectWorkspaceTests {
        private func textView(in view: NSView) -> NSTextView? {
            if let text = view as? NSTextView { return text }

            return view.subviews.lazy.compactMap { textView(in: $0) }.first
        }

        private func waitFor(_ condition: () -> Bool) async throws {
            let end = ContinuousClock.now + .seconds(10)
            while !condition(), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(5)) }
            try #require(condition())
        }

        @Test func realFilesReuseEditorsUndoSelectionScrollAndSaveAcrossTabs() async throws {
            _ = NSApplication.shared
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftIDE-workspace-\(UUID())").resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let original = String(repeating: "Some text on a line\n", count: 300)
            try original.write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
            try "second".write(to: root.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("alias.txt"), withDestinationURL: root.appendingPathComponent("a.txt"))
            let app = AppDelegate(composition: AppCompositionRoot(recoveryStore: MemoryRecoveryStore()))
            let project = app.openProject(path: root.path)
            project.layout.onSave = nil // disposable roots must not persist layout preferences
            defer { project.closeProject() }
            #expect(app.openProject(path: root.path + "/.") === project)
            project.files.onExclusionsChange = nil // this test uses disposable paths, not the user's settings
            project.files.exclude(root.appendingPathComponent("a.txt").path)
            await app.open(path: root.appendingPathComponent("a.txt").path)
            let a = try #require(project.documents.first)
            let content = try #require(a.window?.contentView)
            let text = try #require(textView(in: content))
            let identity = ObjectIdentifier(text)
            a.window?.contentView?.layoutSubtreeIfNeeded()
            text.insertText("Edited ", replacementRange: NSRange(location: 0, length: 0))
            #expect(a.session.isDirty && a.window?.isDocumentEdited == true)
            #expect(a.window?.tab.title.contains("●") == true)
            #expect(project.files.decoration(for: a.session.path).isUnsaved)
            text.setSelectedRange(NSRange(location: 3500, length: 8))
            text.scrollRangeToVisible(text.selectedRange())
            let selection = text.selectedRange()
            let scroll = try #require(text.enclosingScrollView)
            let position = scroll.contentView.bounds.origin
            #expect(position.y > 0, "test must actually scroll the first editor")
            await app.open(path: root.appendingPathComponent("b.txt").path)
            #expect(project.documents.count == 2)
            let b = try #require(project.documents.last)
            let shellA = try #require(a.workspaceShell)
            let shellB = try #require(b.workspaceShell)
            #expect(shellA.state === project.layout && shellB.state === project.layout)
            #expect(a.window?.tabGroup === b.window?.tabGroup)
            b.toggleFocusEditor(nil)
            #expect(project.layout.isFocused && project.layout.layout.left == nil)
            a.toggleFocusEditor(nil)
            #expect(!project.layout.isFocused && project.layout.layout.left == .files)
            let unavailable = NSMenuItem(title: "Source Control", action: #selector(WorkspaceWindowController.showPreviewSourceControl(_:)), keyEquivalent: "")
            #expect(!a.validateMenuItem(unavailable))
            let reset = NSMenuItem(title: "Reset Layout", action: #selector(WorkspaceWindowController.resetWorkspaceLayout(_:)), keyEquivalent: "")
            #expect(a.validateMenuItem(reset))
            a.resetWorkspaceLayout(nil)
            await app.open(path: root.appendingPathComponent("alias.txt").path)
            #expect(project.documents.count == 2, "canonical registry identity, no duplicate editor")
            #expect(a.window?.tabGroup?.selectedWindow === a.window)
            let retainedContent = try #require(a.window?.contentView)
            let retainedText = try #require(textView(in: retainedContent))
            #expect(ObjectIdentifier(retainedText) == identity)
            #expect(text.selectedRange() == selection)
            #expect(scroll.contentView.bounds.origin == position)
            #expect(text.undoManager?.canUndo == true)
            text.undoManager?.undo()
            #expect(a.session.text == original)
            text.insertText("Saved ", replacementRange: NSRange(location: 0, length: 0))
            #expect(await a.save())
            #expect(!a.session.isDirty && a.window?.isDocumentEdited == false)
            #expect(a.window?.tab.title.contains("●") == false)
            #expect(try String(contentsOf: root.appendingPathComponent("a.txt"), encoding: .utf8) == a.session.text)
            #expect(await a.saveAs(to: root.appendingPathComponent("renamed.txt"), target: .newFile))
            #expect(a.session.path == root.appendingPathComponent("renamed.txt").path)
            #expect(a.window?.tab.title == "renamed.txt")
            let end = ContinuousClock.now + .seconds(10)
            while !project.files.children(of: root.path).contains(where: { $0.name == "renamed.txt" }), ContinuousClock.now < end {
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(project.files.children(of: root.path).contains { $0.name == "renamed.txt" }, "state: \(project.files.state(of: root.path)); expanded: \(project.files.expanded)")
            await app.open(path: a.session.path)
            #expect(project.documents.count == 2 && project.documents.first === a)
        }

        @Test func cancelledTabCloseKeepsTheDocumentAndLastClosedTabReturnsToFiles() async throws {
            _ = NSApplication.shared
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftIDE-close-tab-\(UUID())").resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            try "original".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
            let app = AppDelegate(composition: AppCompositionRoot(recoveryStore: MemoryRecoveryStore()))
            let project = app.openProject(path: root.path)
            project.layout.onSave = nil // disposable roots must not persist layout preferences
            defer { project.closeProject() }
            await app.open(path: root.appendingPathComponent("a.txt").path)
            let document = try #require(project.documents.first)
            try document.session.replaceText("dirty", expectedVersion: 0)
            let window = try #require(document.window)
            #expect(!document.windowShouldClose(window))
            try await waitFor { window.attachedSheet != nil }
            window.endSheet(try #require(window.attachedSheet), returnCode: .alertSecondButtonReturn)
            try await waitFor { window.attachedSheet == nil }
            #expect(project.documents.count == 1 && document.session.text == "dirty")
            // The shared project close procedure must also respect Cancel.
            let closing = Task { await app.closeProject(project) }
            try await waitFor { window.attachedSheet != nil }
            window.endSheet(try #require(window.attachedSheet), returnCode: .alertSecondButtonReturn)
            await closing.value
            #expect(project.documents.count == 1)
            // Discard from the existing coordinator closes only this tab, then the empty browser returns.
            #expect(!document.windowShouldClose(window))
            try await waitFor { window.attachedSheet != nil }
            window.endSheet(try #require(window.attachedSheet), returnCode: .alertThirdButtonReturn)
            try await waitFor { project.documents.isEmpty }
            #expect(project.window?.isVisible == true)
            #expect(try String(contentsOf: root.appendingPathComponent("a.txt"), encoding: .utf8) == "original")
        }

        @Test func exclusionsPersistByCanonicalRootAndRemainIndependentAcrossProjects() throws {
            let suite = "SwiftIDE.files.tests.\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let settings = ProjectFilesSettings(defaults: defaults)
            settings.save(.init(explicit: ["Sources/Generated"], includedDefaults: [".build"]), root: "/w")
            #expect(ProjectFilesSettings(defaults: defaults).load(root: "/w/.") == .init(explicit: ["Sources/Generated"], includedDefaults: [".build"]))
            #expect(settings.load(root: "/other") == .init())
            let layouts = WorkspaceLayoutSettings(defaults: defaults)
            let first = layouts.makeState(root: "/w")
            first.resize(left: 330)
            first.toggleFocus()
            let reopened = layouts.makeState(root: "/w/.")
            #expect(reopened.layout.left == .files && reopened.layout.leftWidth == 330)
            #expect(!reopened.isFocused)
            #expect(layouts.makeState(root: "/other").layout.leftWidth == 260)
            reopened.select(.files)
            #expect(layouts.makeState(root: "/w").layout.left == nil)
        }

        @Test func openingAndReleasingAFolderKeepsAnAlreadyOpenEditorAndItsUndo() async throws {
            _ = NSApplication.shared
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftIDE-adopt-editor-\(UUID())").resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let file = root.appendingPathComponent("existing.txt")
            try "original".write(to: file, atomically: true, encoding: .utf8)
            let app = AppDelegate(composition: AppCompositionRoot(recoveryStore: MemoryRecoveryStore()))
            await app.open(path: file.path)
            let window = try #require(NSApp.windows.first { $0.representedURL?.path == DocumentPath.canonical(file.path) })
            defer { window.close() }
            let initialContent = try #require(window.contentView)
            let editor = try #require(textView(in: initialContent))
            editor.insertText("edit ", replacementRange: NSRange(location: 0, length: 0))
            let project = app.openProject(path: root.path)
            project.layout.onSave = nil // disposable roots must not persist layout preferences
            let document = try #require(project.documents.first)
            #expect(document.window === window && document.session.isDirty)
            let groupedContent = try #require(window.contentView)
            #expect(textView(in: groupedContent) === editor)
            app.closeOpenedFolders(nil)
            #expect(project.documents.isEmpty && window.isVisible)
            let releasedContent = try #require(window.contentView)
            #expect(textView(in: releasedContent) === editor)
            editor.undoManager?.undo()
            #expect(document.session.text == "original")
        }
    }
}
