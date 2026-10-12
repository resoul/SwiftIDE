import AppKit
import IDEApplication
import IDEDomain
import LanguageInfrastructure
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

        private func outline(in view: NSView) -> NSOutlineView? {
            if let outline = view as? NSOutlineView { return outline }

            return view.subviews.lazy.compactMap { outline(in: $0) }.first
        }

        private func waitFor(_ condition: () -> Bool) async throws {
            let end = ContinuousClock.now + .seconds(10)
            while !condition(), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(5)) }
            try #require(condition())
        }

        @Test func realFilesReuseEditorsUndoSelectionScrollAndSaveAcrossTabs() async throws {
            _ = NSApplication.shared
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftIDE-workspace-\(UUID())")
                .resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let original = String(repeating: "Some text on a line\n", count: 300)
            try original.write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
            try "second".write(to: root.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
            try FileManager.default.createSymbolicLink(
                at: root.appendingPathComponent("alias.txt"),
                withDestinationURL: root.appendingPathComponent("a.txt")
            )
            let app = AppDelegate(composition: AppCompositionRoot(
                recoveryStore: MemoryRecoveryStore(),
                recentStore: MemoryRecentProjectsStore()
            ))
            let project = app.openProject(path: root.path)
            project.layout.onSave = nil // disposable roots must not persist layout preferences
            defer { project.closeProject(); app.welcome?.close() }
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
            #expect(project.area.tabs.items.first { $0.id == a.session.id }?.decoration.isUnsaved == true)
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
            #expect(project.shell.state === project.layout)
            #expect(a.window === project.window && b.window === project.window)
            #expect(project.window?.tabGroup == nil)
            #expect(project.area.active === b)
            project.toggleFocusEditor(nil)
            #expect(project.layout.isFocused && project.layout.layout.left == nil)
            project.toggleFocusEditor(nil)
            #expect(!project.layout.isFocused && project.layout.layout.left == .files)
            let sourceControl = NSMenuItem(
                title: "Source Control",
                action: #selector(ProjectWorkspaceController.showPreviewSourceControl(_:)),
                keyEquivalent: ""
            )
            #expect(project.validateMenuItem(sourceControl))
            project.showPreviewSourceControl(nil)
            #expect(project.layout.layout.left == .sourceControl)
            try await waitFor { project.git?.state == .unavailable("This folder is not in a Git repository") }
            #expect(project.files.statusExplanation.contains("not in a Git repository"))
            project.showPreviewFiles(nil)
            let reset = NSMenuItem(
                title: "Reset Layout",
                action: #selector(ProjectWorkspaceController.resetWorkspaceLayout(_:)),
                keyEquivalent: ""
            )
            #expect(project.validateMenuItem(reset))
            project.resetWorkspaceLayout(nil)
            await app.open(path: root.appendingPathComponent("alias.txt").path)
            #expect(project.documents.count == 2, "canonical registry identity, no duplicate editor")
            #expect(project.activeDocument === a)
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
            #expect(project.area.tabs.items.first { $0.id == a.session.id }?.decoration.isUnsaved == false)
            #expect(try String(contentsOf: root.appendingPathComponent("a.txt"), encoding: .utf8) == a.session.text)
            #expect(await a.saveAs(to: root.appendingPathComponent("renamed.txt"), target: .newFile))
            #expect(a.session.path == root.appendingPathComponent("renamed.txt").path)
            #expect(project.area.tabs.items.first { $0.id == a.session.id }?.name == "renamed.txt")
            let end = ContinuousClock.now + .seconds(10)
            while !project.files.children(of: root.path).contains(where: { $0.name == "renamed.txt" }),
                  ContinuousClock.now < end {
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(
                project.files.children(of: root.path).contains { $0.name == "renamed.txt" },
                "state: \(project.files.state(of: root.path)); expanded: \(project.files.expanded)"
            )
            await app.open(path: a.session.path)
            #expect(project.documents.count == 2 && project.documents.first === a)
        }

        @Test func cancelledTabCloseKeepsTheDocumentAndLastClosedTabReturnsToFiles() async throws {
            _ = NSApplication.shared
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftIDE-close-tab-\(UUID())")
                .resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            try "original".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
            let app = AppDelegate(composition: AppCompositionRoot(
                recoveryStore: MemoryRecoveryStore(),
                recentStore: MemoryRecentProjectsStore()
            ))
            let project = app.openProject(path: root.path)
            project.layout.onSave = nil // disposable roots must not persist layout preferences
            defer { project.closeProject(); app.welcome?.close() }
            await app.open(path: root.appendingPathComponent("a.txt").path)
            let document = try #require(project.documents.first)
            try document.session.replaceText("dirty", expectedVersion: 0)
            let window = try #require(document.window)
            document.requestClose()
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
            document.requestClose()
            try await waitFor { window.attachedSheet != nil }
            window.endSheet(try #require(window.attachedSheet), returnCode: .alertThirdButtonReturn)
            try await waitFor { project.documents.isEmpty }
            #expect(project.window?.isVisible == true)
            #expect(try String(contentsOf: root.appendingPathComponent("a.txt"), encoding: .utf8) == "original")
        }

        @Test func reorderedTabsKeepTheSingleShellAndCommandsSaveTheirCapturedDocument() async throws {
            _ = NSApplication.shared
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftIDE-central-tabs-\(UUID())")
                .resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            for name in ["README.md", "notes.txt", "third.txt"] {
                try "original \(name)\n".write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
            }
            let app = AppDelegate(composition: AppCompositionRoot(
                recoveryStore: MemoryRecoveryStore(),
                recentStore: MemoryRecentProjectsStore()
            ))
            let project = app.openProject(path: root.path)
            project.layout.onSave = nil
            defer { project.closeProject(); app.welcome?.close() }
            for name in ["README.md", "notes.txt", "third.txt"] {
                await app.open(path: root.appendingPathComponent(name).path)
            }
            let a = try #require(project.documents.first), b = project.documents[1], c = project.documents[2]
            let window = try #require(project.window)
            let shell = project.shell
            let tree = try #require(project.shell.view.subviews.first)
            let filesOutline = try #require(outline(in: shell.view))
            window.makeFirstResponder(filesOutline)
            project.tabs.move(a.session.id, to: 3)
            #expect(window.firstResponder === filesOutline, "reordering must not steal focus from a tool panel")
            #expect(project.documents.map(\.session.id) == [b.session.id, c.session.id, a.session.id])
            #expect(project.activeDocument === c && project.shell === shell)
            #expect(tree.superview === shell.view)
            #expect(project.documents.allSatisfy { $0.window === window })
            #expect(window.tabGroup == nil)
            project.select(a.session.id)
            try a.session.replaceText("unsaved A", expectedVersion: a.session.version)
            project.select(b.session.id)
            try b.session.replaceText("save B", expectedVersion: b.session.version)
            project.saveDocument(nil)
            project.select(a.session.id) // change the active tab before the save task starts
            try await waitFor { !b.session.isDirty }
            #expect(a.session.isDirty)
            #expect(try String(contentsOf: root.appendingPathComponent("notes.txt"), encoding: .utf8) == "save B")
            #expect(try String(contentsOf: root.appendingPathComponent("README.md"), encoding: .utf8)
                .hasPrefix("original"))
            project.select(c.session.id)
            project.closeDocument(nil)
            try await waitFor { project.documents.count == 2 }
            #expect(!project.documents.contains { $0 === c })
            #expect(window.isVisible && project.activeDocument === a)
            try await Task.sleep(for: .milliseconds(50))
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                window.appearance = NSAppearance(named: appearance)
                window.contentView?.layoutSubtreeIfNeeded()
                let view = try #require(window.contentView)
                let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: URL(fileURLWithPath: "/private/tmp/swiftide-content-tabs-\(name).png"))
            }
            project.toggleFocusEditor(nil)
            window.contentView?.layoutSubtreeIfNeeded()
            #expect(project.area.tabs.view.isDescendant(of: shell.view))
            #expect(project.area.view.bounds.width > 1200)
            #expect(project.area.view.bounds.height > 700)
            project.toggleFocusEditor(nil)
            #expect(project.layout.layout.left == .files)
        }

        @Test func definitionAndOutsideFilesUseTheOriginatingProjectContent() async throws {
            _ = NSApplication.shared
            let base = FileManager.default.temporaryDirectory
                .appendingPathComponent("SwiftIDE-definition-tabs-\(UUID())").resolvingSymlinksInPath()
            let root = base.appendingPathComponent("project"), sdk = base.appendingPathComponent("Mock.sdk")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: sdk, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: base) }
            let source = root.appendingPathComponent("a.txt"), definition = sdk.appendingPathComponent("symbol.txt"),
                outside = base.appendingPathComponent("outside.txt")
            for url in [source, definition, outside] {
                try "line one\nline two\n".write(to: url, atomically: true, encoding: .utf8)
            }
            let app = AppDelegate(composition: AppCompositionRoot(
                recoveryStore: MemoryRecoveryStore(),
                recentStore: MemoryRecentProjectsStore()
            ))
            let project = app.openProject(path: root.path)
            project.layout.onSave = nil
            defer { project.closeProject(); app.welcome?.close() }
            await app.open(path: source.path)
            let first = try #require(project.documents.first)
            first.onOpenLocation?(DefinitionLocation(path: definition.path, line: 1, character: 2))
            try await waitFor { project.documents.count == 2 }
            let target = try #require(project.activeDocument)
            #expect(target.session.path == definition.path && target.window === project.window)
            let text = try #require(target.focusTarget as? NSTextView)
            #expect(!text.isEditable && text.selectedRange().location == 11)
            await app.open(path: outside.path, in: project)
            #expect(project.documents.count == 3 && project.activeDocument?.window === project.window)
            #expect(!NSApp.windows.contains {
                $0.windowController is WorkspaceWindowController && $0.representedURL?.path == outside.path
            })
            project.closeProject()
            // A late opening for a closed project must not resurrect its window or retain a registry entry.
            await app.open(path: outside.path, in: project)
            #expect(project.documents.isEmpty)
            await app.open(path: outside.path)
            let standalone = try #require(NSApp.windows.first {
                $0.isVisible && $0.representedURL?.path == outside.path
            })
            defer { standalone.close() }
            #expect(standalone.windowController is WorkspaceWindowController)
        }

        @Test func closingBeforeDeferredAttachmentCannotStartALanguageServer() async throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftIDE-closed-editor-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let file = root.appendingPathComponent("a.swift")
            try "let x = 1".write(to: file, atomically: true, encoding: .utf8)
            let composition = AppCompositionRoot(
                recoveryStore: MemoryRecoveryStore(),
                recentStore: MemoryRecentProjectsStore()
            )
            var starts = 0
            let services = LanguageServices(
                scratchRoot: root.appendingPathComponent("scratch"),
                languages: composition.languages,
                makeService: { url, _ in
                starts += 1

                return SourceKitLanguageService(workspaceRoot: url, channelFactory: { throw LSPError.notRunning })
            }
            )
            composition.languageServices = services
            let opened = try await composition.open(path: file.path)
            let document = composition.makeDocument(for: opened.session)
            document.onClose = { composition.close($0.session) }
            document.close()
            try await Task.sleep(for: .milliseconds(30))
            #expect(document.isClosed && starts == 0 && services.runningRoots.isEmpty)
        }

        @Test func exclusionsPersistByCanonicalRootAndRemainIndependentAcrossProjects() throws {
            let suite = "SwiftIDE.files.tests.\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let settings = ProjectFilesSettings(defaults: defaults)
            settings.save(.init(explicit: ["Sources/Generated"], includedDefaults: [".build"]), root: "/w")
            #expect(ProjectFilesSettings(defaults: defaults).load(root: "/w/.") == .init(
                explicit: ["Sources/Generated"],
                includedDefaults: [".build"]
            ))
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
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftIDE-adopt-editor-\(UUID())")
                .resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let file = root.appendingPathComponent("existing.txt")
            try "original".write(to: file, atomically: true, encoding: .utf8)
            let app = AppDelegate(composition: AppCompositionRoot(
                recoveryStore: MemoryRecoveryStore(),
                recentStore: MemoryRecentProjectsStore()
            ))
            await app.open(path: file.path)
            let window = try #require(NSApp.windows.first {
                $0.representedURL?.path == DocumentPath.canonical(file.path)
            })
            defer { window.close(); app.welcome?.close() }
            let initialContent = try #require(window.contentView)
            let editor = try #require(textView(in: initialContent))
            editor.insertText("edit ", replacementRange: NSRange(location: 0, length: 0))
            let project = app.openProject(path: root.path)
            project.layout.onSave = nil // disposable roots must not persist layout preferences
            let document = try #require(project.documents.first)
            #expect(document.window === project.window && document.session.isDirty)
            #expect(window.isVisible == false)
            let groupedContent = try #require(project.window?.contentView)
            #expect(textView(in: groupedContent) === editor)
            app.closeOpenedFolders(nil)
            #expect(project.documents.isEmpty)
            let releasedWindow = try #require(document.window)
            defer { releasedWindow.close() }
            #expect(releasedWindow.isVisible)
            let releasedContent = try #require(releasedWindow.contentView)
            #expect(textView(in: releasedContent) === editor)
            editor.undoManager?.undo()
            #expect(document.session.text == "original")
        }
    }
}
