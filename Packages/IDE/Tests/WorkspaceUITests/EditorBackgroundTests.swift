import AppKit
import AgentInfrastructure
import ChatUI
import EditorPlatformTextKit
import EditorUI
import IDEApplication
import IDEDomain
import Testing
@testable import WorkspaceUI

@Suite(.serialized) @MainActor
struct EditorBackgroundTests {
    @Test func filesEditorChatAndGitPanelsShareTheBackgroundAcrossThemeChanges() async throws {
        _ = NSApplication.shared
        let filesModel = ProjectFiles(root: "/preview/SwiftIDE", reader: ThemeDirectoryReader())
        let files = ProjectFilesViewController(model: filesModel)
        let agent = AgentSession(provider: DemoAgentProvider())
        let chat = ChatPanelViewController(session: agent)
        let git = GitWorkspace(root: filesModel.root, service: ThemeGit())
        let log = GitLogViewController(model: git)
        let area = EditorAreaViewController()
        let editor = TextKitEditorFactory.makeEditor(loadedText: "let value = 1\n")
        let document = NSViewController()
        document.view = EditorHostView(editor: editor)
        area.show(document, focusTarget: editor.textView)
        let id = DocumentID()
        area.tabs.present([.init(id: id, name: "Main.swift", path: "/preview/SwiftIDE/Main.swift")], selected: id)
        var geometry = WorkspaceLayout()
        geometry.right = .assistant
        geometry.bottom = .gitLog
        geometry.rightWidth = 360
        let layout = WorkspaceLayoutState(layout: geometry, available: [.files, .assistant, .gitLog])
        let shell = WorkspaceShellViewController(
            state: layout,
            editor: area.view,
            panels: [
                .files: .init(view: files.view),
                .assistant: .init(view: chat.view),
                .gitLog: .init(view: log.view)
            ],
            project: "SwiftIDE",
            path: filesModel.root
        )
        for child in [files, chat, log, area] as [NSViewController] { shell.addChild(child) }
        let window = NSWindow(
            contentRect: NSRect(x: -2000, y: -2000, width: 1440, height: 900),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = shell
        window.setContentSize(NSSize(width: 1440, height: 900))
        shell.installWindowToolbar(on: window)
        defer {
            files.disconnect()
            filesModel.stop()
            chat.disconnect()
            agent.stop()
            log.disconnect()
            git.stop()
            shell.disconnect()
            window.close()
        }
        git.refresh()
        let deadline = ContinuousClock.now + .seconds(5)
        while (filesModel.state(of: filesModel.root) != .loaded || git.historyState != .ready),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(filesModel.state(of: filesModel.root) == .loaded && git.historyState == .ready)
        for (name, appearance, expected) in [
            ("dark", NSAppearance.Name.darkAqua, CGFloat(0)),
            ("light", .aqua, CGFloat(1)),
            ("dark-again", .darkAqua, CGFloat(0))
        ] {
            window.appearance = NSAppearance(named: appearance)
            try await Task.sleep(for: .milliseconds(50))
            shell.view.layoutSubtreeIfNeeded()
            for panel in [
                files.view,
                files.outline,
                area.view,
                chat.view,
                chat.focusTarget,
                log.view,
                log.commits.table
            ] {
                panel.layoutSubtreeIfNeeded()
                let bitmap = try #require(panel.bitmapImageRepForCachingDisplay(in: panel.bounds))
                panel.cacheDisplay(in: panel.bounds, to: bitmap)
                try #require(bitmap.pixelsWide > 30 && bitmap.pixelsHigh > 10)
                let colour = try #require(bitmap.colorAt(
                    x: bitmap.pixelsWide - 24,
                    y: bitmap.pixelsHigh / 2
                )?.usingColorSpace(.deviceRGB))
                #expect(abs(colour.redComponent - expected) < 0.005)
                #expect(abs(colour.greenComponent - expected) < 0.005)
                #expect(abs(colour.blueComponent - expected) < 0.005)
            }
            if ProcessInfo.processInfo.environment["SWIFTIDE_RENDER_EDITOR"] == "1" {
                let bitmap = try #require(shell.view.bitmapImageRepForCachingDisplay(in: shell.view.bounds))
                shell.view.cacheDisplay(in: shell.view.bounds, to: bitmap)
                try #require(bitmap.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: "/private/tmp/swiftide-workspace-theme-\(name).png"))
            }
        }
    }

    @Test func tabStripEmptyAreaTextAndGutterStayBlackOrWhiteAcrossThemeChanges() async throws {
        _ = NSApplication.shared
        let area = EditorAreaViewController()
        let editor = TextKitEditorFactory.makeEditor(loadedText: "let value = 1\n")
        let session = DocumentSession(path: "Main.swift", backend: editor.backend)
        let index = DocumentLineIndex(session: session, source: editor.backend)
        let document = NSViewController()
        document.view = EditorHostView(editor: editor, lineIndex: index)
        let window = NSWindow(
            contentRect: NSRect(x: -2000, y: -2000, width: 640, height: 380),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = area
        window.setContentSize(NSSize(width: 640, height: 380))
        defer { window.close() }

        for (name, appearance, expected) in [
            ("dark", NSAppearance.Name.darkAqua, CGFloat(0)),
            ("light", .aqua, CGFloat(1)),
            ("dark-again", .darkAqua, CGFloat(0))
        ] {
            window.appearance = NSAppearance(named: appearance)
            for open in [false, true] {
                area.show(open ? document : nil, focusTarget: open ? editor.textView : nil)
                area.tabs.present(
                    open ? [.init(id: session.id, name: "Main.swift", path: "Main.swift")] : [],
                    selected: open ? session.id : nil
                )
                try await Task.sleep(for: .milliseconds(50))
                area.view.layoutSubtreeIfNeeded()
                area.view.displayIfNeeded()
                let bitmap = try #require(area.view.bitmapImageRepForCachingDisplay(in: area.view.bounds))
                area.view.cacheDisplay(in: area.view.bounds, to: bitmap)
                try #require(bitmap.pixelsWide > 100 && bitmap.pixelsHigh > 100)
                let right = bitmap.pixelsWide - 30
                for (x, y) in [
                    (right, 20),
                    (right, 70),
                    (right, bitmap.pixelsHigh - 30),
                    (8, bitmap.pixelsHigh - 30)
                ] {
                    let colour = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                    #expect(abs(colour.redComponent - expected) < 0.005)
                    #expect(abs(colour.greenComponent - expected) < 0.005)
                    #expect(abs(colour.blueComponent - expected) < 0.005)
                    #expect(colour.alphaComponent > 0.99)
                }
                if ProcessInfo.processInfo.environment["SWIFTIDE_RENDER_EDITOR"] == "1" {
                    let state = open ? "open" : "empty"
                    try #require(bitmap.representation(using: .png, properties: [:]))
                        .write(to: URL(fileURLWithPath: "/private/tmp/swiftide-editor-\(name)-\(state).png"))
                }
            }
        }
    }
}

private struct ThemeDirectoryReader: ProjectDirectoryReading {
    func children(of path: String) async throws -> [ProjectFile] {
        [ProjectFile(path: path + "/Main.swift", isDirectory: false)]
    }
}

private struct ThemeGit: GitInspecting {
    private let oid = String(repeating: "a", count: 40)

    func snapshot(at projectRoot: String) async throws -> GitSnapshot {
        .init(
            repository: .init(
                root: projectRoot,
                gitDirectory: projectRoot + "/.git",
                commonDirectory: projectRoot + "/.git"
            ),
            branch: "main",
            head: oid,
            changes: [],
            branches: []
        )
    }

    func history(
        in repository: GitRepository,
        revision: String,
        offset: Int,
        count: Int
    ) async throws -> GitHistoryPage {
        .init(
            commits: [.init(
                oid: oid,
                parents: [],
                author: "Demo",
                date: Date(timeIntervalSince1970: 0),
                subject: "Initial commit"
            )],
            hasMore: false
        )
    }

    func files(in repository: GitRepository, commit: GitCommit) async throws -> [GitCommitFile] { [] }

    func diff(in repository: GitRepository, comparison: GitComparison) async throws -> String { "" }
}
