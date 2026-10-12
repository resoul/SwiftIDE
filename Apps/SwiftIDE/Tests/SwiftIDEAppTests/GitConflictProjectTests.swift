import AppKit
import IDEApplication
import IDETestSupport
import Testing
@testable import SwiftIDE

extension NativeAppTests {
    @Suite(.serialized) @MainActor
    struct GitConflictProjectTests {
        private func wait(_ label: String = "condition", _ predicate: () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(20)
            while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
            try #require(predicate(), "Timed out: \(label)")
        }
        @Test(arguments: [GitIntegrationKind.merge, .rebase])
        func nativeConflictResultPreservesEditorUndoAndCompletesReviewedOperation(
            kind: GitIntegrationKind
        ) async throws {
            _ = NSApplication.shared
            let fixture = try NativeConflictFixture(); defer { fixture.remove() }
            var saves = 0
            let app = AppDelegate(
                composition: AppCompositionRoot(
                    recoveryStore: MemoryRecoveryStore(),
                    recentStore: MemoryRecentProjectsStore()
                ),
                gitCheckoutPrompt: { _ in
                saves += 1

                return .save
            }
            )
            let project = app.openProject(path: fixture.root.path)
            project.layout.onSave = nil; project.files.onExclusionsChange = nil
            project.showWorkspace()
            defer { project.closeProject(); app.welcome?.close() }
            let model = try #require(project.git)
            try await wait { model.canMutate }
            await app.open(path: fixture.root.appendingPathComponent("a.txt").path, in: project)
            let document = try #require(project.activeDocument),
                editor = try #require(document.focusTarget as? NSTextView)
            let before = try #require(model.snapshot)
            let target = try #require(before.branches.first { $0.name == "incoming" })
            project.showIntegration(kind, target: target)
            let form = try #require(project.integrationWindow)
            #expect(project.window?.attachedSheet === form.window)
            form.content.start?(.init(
                repository: before.repository,
                kind: kind,
                head: try #require(before.head),
                branch: "main",
                target: target
            ))
            #expect(project.integrationWindow == nil && project.window?.attachedSheet == nil)
            try await wait {
                model.canMutate && model.snapshot?.changes
                    .contains(where: { $0.decoration.isConflict }) == true && document.session.text.hasPrefix("<<<<<<<")
            }
            #expect(editor.isEditable && model.snapshot?.integration?.kind == kind)
            let change = try #require(model.snapshot?.changes.first { $0.decoration.isConflict })
            project.showConflict(change)
            try await wait("conflict preview ready") {
                project.area.active is GitConflictEditorController && model.canMutate
            }
            let context = try #require(project.area.active as? GitConflictEditorController)
            #expect(context.document === document && document.parent === context && context.context.resultHost.subviews
                .first === document.view)
            #expect(context.context.conflict.sides.first { $0.stage == 2 }?.text == (kind == .rebase
                ? "incoming\n"
                : "local\n"))
            let chosen = try #require(context.context.conflict.sides.first { $0.stage == 3 })
            context.context.takeTextSide?(chosen)
            try await wait { document.session.text == chosen.text }
            #expect(editor.undoManager?.canUndo == true && project.activeDocument === document)
            editor.undoManager?.undo(); #expect(document.session.text.hasPrefix("<<<<<<<"))
            editor.insertText(
                "reviewed result\n",
                replacementRange: NSRange(location: 0, length: document.session.utf16Length)
            )
            context.context.resolveWorking?()
            try await wait {
                model.canMutate && model.snapshot?.changes.contains(where: { $0.decoration.isConflict }) == false
            }
            #expect(saves == 1 && !document.session.isDirty && editor.isEditable && editor.undoManager?.canUndo == true)
            let status = try #require(model.snapshot?.integration)
            model.perform(.continueIntegration(status, kind == .merge ? "Reviewed merge" : ""))
            try await wait {
                model.operationState == .succeeded && model.canMutate && model.snapshot?.integration == nil
            }
            #expect(try fixture.git(["show", "HEAD:a.txt"]) == Data("reviewed result\n".utf8))
            #expect(model.snapshot?.branch == "main")
            context.context.closePreview?()
            #expect(project.area.active === document && document.focusTarget === editor)
            editor.undoManager?.undo()
            #expect(
                document.session.text != "reviewed result\n",
                "Native Undo survives preview, save and integration; it does not undo Git commits"
            )
        }
        @Test func binaryConflictUsesCentralToolAndDeletionNeedsExplicitApproval() async throws {
            _ = NSApplication.shared
            let fixture = try NativeConflictFixture(binary: true); defer { fixture.remove() }
            let app = AppDelegate(composition: AppCompositionRoot(
                recoveryStore: MemoryRecoveryStore(),
                recentStore: MemoryRecentProjectsStore()
            ))
            let project = app.openProject(path: fixture.root.path)
            project.layout.onSave = nil; project.files.onExclusionsChange = nil
            project.showWorkspace()
            defer { project.closeProject(); app.welcome?.close() }
            let model = try #require(project.git)
            try await wait { model.canMutate }
            let before = try #require(model.snapshot), target = try #require(before.branches.first {
                $0.name == "incoming"
            })
            model.perform(.integrate(.init(
                repository: before.repository,
                kind: .merge,
                head: try #require(before.head),
                branch: "main",
                target: target
            )))
            try await wait {
                model.canMutate && model.snapshot?.changes.contains(where: { $0.decoration.isConflict }) == true
            }
            project.showConflict(try #require(model.snapshot?.changes.first { $0.decoration.isConflict }))
            try await wait("conflict preview ready") {
                project.area.active is GitConflictEditorController && model.canMutate
            }
            let context = try #require(project.area.active as? GitConflictEditorController)
            #expect(context.document == nil && project.documents.isEmpty && project.area.tabs.items.contains {
                $0.name.hasPrefix("Resolve ·")
            })
            let bytes = try Data(contentsOf: fixture.root.appendingPathComponent("a.txt"))
            context.context.resolveDeleted?()
            try await wait("destructive confirmation attached") { project.window?.attachedSheet != nil }
            let sheet = try #require(project.window?.attachedSheet)
            project.window?.endSheet(sheet, returnCode: .alertFirstButtonReturn)
            for _ in 0..<20 { await Task.yield() }
            #expect(try Data(contentsOf: fixture.root.appendingPathComponent("a.txt")) == bytes && model.snapshot?
                .changes.contains(where: { $0.decoration.isConflict }) == true)
        }
    }
}

private final class NativeConflictFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftIDE-conflict-app-\(UUID())")
        .resolvingSymlinksInPath()

    init(binary: Bool = false) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try git(["init", "-b", "main"])
        try git(["config", "user.name", "Author"])
        try git(["config", "user.email", "test@example.test"])
        try git(["config", "commit.gpgsign", "false"])
        func write(_ value: String) throws {
            try (value + (binary ? "\0binary" : "\n")).write(
                to: root.appendingPathComponent("a.txt"),
                atomically: true,
                encoding: .utf8
            )
        }
        try write("base"); try git(["add", "."]); try git(["commit", "-m", "Base"])
        try git(["switch", "-c", "incoming"]); try write("incoming"); try git(["commit", "-am", "Incoming"])
        try git(["switch", "main"]); try write("local"); try git(["commit", "-am", "Local"])
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
    @discardableResult func git(_ arguments: [String]) throws -> Data {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git"); process.arguments = ["-C", root.path] + arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run(); let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        try #require(process.terminationStatus == 0)

        return data
    }
}
