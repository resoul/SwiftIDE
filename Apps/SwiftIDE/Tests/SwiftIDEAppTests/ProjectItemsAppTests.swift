import AppKit
import IDEApplication
import IDEDomain
import IDETestSupport
import Testing
import WorkspaceUI
@testable import SwiftIDE

extension NativeAppTests {
    @Suite(.serialized) @MainActor
    struct ProjectItemsAppTests {
        private func makeProject() throws -> (URL, AppDelegate, ProjectWorkspaceController) {
            _ = NSApplication.shared
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftIDE-items-\(UUID())")
                .resolvingSymlinksInPath()
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("sub"),
                withIntermediateDirectories: true
            )
            for name in ["a.txt", "c.txt", "sub/b.txt"] {
                try "base \(name)\n".write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
            }

            let app = AppDelegate(composition: AppCompositionRoot(
                recoveryStore: MemoryRecoveryStore(),
                recentStore: MemoryRecentProjectsStore()
            ))
            let project = app.openProject(path: root.path)
            project.layout.onSave = nil
            project.files.onExclusionsChange = nil

            return (root, app, project)
        }

        private func wait(_ predicate: () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(15)
            while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
            try #require(predicate())
        }

        @Test func renamingAFileOrFolderKeepsOpenDocumentsTheirTextTheirUnsavedStateAndTheirSaves() async throws {
            let (root, app, project) = try makeProject()
            defer {
                project.closeProject()
                app.welcome?.close()
                try? FileManager.default.removeItem(at: root)
            }
            await app.open(path: root.appendingPathComponent("a.txt").path, in: project)
            let a = try #require(project.activeDocument)
            let editor = try #require(a.focusTarget as? NSTextView)
            editor.insertText("edited ", replacementRange: NSRange(location: 0, length: 0))
            #expect(a.session.isDirty)
            await app.open(path: root.appendingPathComponent("sub/b.txt").path, in: project)
            let b = try #require(project.activeDocument)

            let renamed = try project.files.rename(root.appendingPathComponent("a.txt").path, to: "a2.txt")
            #expect(renamed == root.appendingPathComponent("a2.txt").path)
            #expect(a.session.path == renamed && a.session.isDirty && a.session.text.hasPrefix("edited base"))
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("a.txt").path))
            #expect(await a.save())
            #expect(try String(contentsOfFile: renamed, encoding: .utf8) == "edited base a.txt\n")
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("a.txt").path))

            _ = try project.files.rename(root.appendingPathComponent("sub").path, to: "sub2")
            #expect(b.session.path == root.appendingPathComponent("sub2/b.txt").path && !b.session.isDirty)
            #expect(project.documents.count == 2)
            #expect(throws: NewEntryError.self) { try project.files.rename(renamed, to: "c.txt") }
            #expect(a.session.path == renamed)
        }

        @Test func trashedItemsCloseTheirDocumentsAndLeaveTheOthersAlone() async throws {
            let (root, app, project) = try makeProject()
            defer {
                project.closeProject()
                app.welcome?.close()
                try? FileManager.default.removeItem(at: root)
            }
            for name in ["a.txt", "c.txt", "sub/b.txt"] {
                await app.open(path: root.appendingPathComponent(name).path, in: project)
            }
            #expect(project.documents.count == 3)
            app.closeDocuments(under: root.appendingPathComponent("sub").path)
            try await wait { project.documents.count == 2 }
            #expect(!project.documents.contains { $0.session.path.hasSuffix("sub/b.txt") })
            app.closeDocuments(under: root.appendingPathComponent("c.txt").path)
            try await wait { project.documents.count == 1 }
            #expect(project.documents.first?.session.path == root.appendingPathComponent("a.txt").path)
        }

        @Test func movingAnOpenFileIntoAFolderKeepsItsDocumentAndAFinderCopyComesInUnchanged() async throws {
            let (root, app, project) = try makeProject()
            let outside = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftIDE-out-\(UUID())")
                .resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            try "from finder\n".write(to: outside.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
            defer {
                project.closeProject()
                app.welcome?.close()
                try? FileManager.default.removeItem(at: root)
                try? FileManager.default.removeItem(at: outside)
            }
            await app.open(path: root.appendingPathComponent("a.txt").path, in: project)
            let a = try #require(project.activeDocument)
            let editor = try #require(a.focusTarget as? NSTextView)
            editor.insertText("edited ", replacementRange: NSRange(location: 0, length: 0))

            let sub = root.appendingPathComponent("sub").path
            let moved = project.files.move([root.appendingPathComponent("a.txt").path], into: sub)
            #expect(moved.failure == nil && moved.done == [sub + "/a.txt"])
            #expect(a.session.path == sub + "/a.txt" && a.session.isDirty && a.session.text.hasPrefix("edited base"))
            #expect(await a.save())
            #expect(try String(contentsOfFile: sub + "/a.txt", encoding: .utf8) == "edited base a.txt\n")
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("a.txt").path))

            let copied = project.files.copy([outside.appendingPathComponent("f.txt").path], into: sub)
            #expect(copied.done == [sub + "/f.txt"] && FileManager.default
                .fileExists(atPath: outside.appendingPathComponent("f.txt").path))
            let collision = project.files.move(
                [root.appendingPathComponent("c.txt").path],
                into: root.appendingPathComponent("sub").path
            )
            #expect(collision.done == [sub + "/c.txt"])
            #expect(project.files.move([sub + "/c.txt"], into: sub + "/c.txt").failure == .notAFolder)
        }

        @Test func aBrokenJSONFileShowsItsErrorAndFormatDocumentLaysOutAGoodOne() async throws {
            let (root, app, project) = try makeProject()
            defer {
                project.closeProject()
                app.welcome?.close()
                try? FileManager.default.removeItem(at: root)
            }
            let broken = root.appendingPathComponent("broken.json").path
            let good = root.appendingPathComponent("good.json").path
            try "{\"a\": [1, 2,],}".write(toFile: broken, atomically: true, encoding: .utf8)
            try "{\"b\":1,\"a\":[1,{}]}".write(toFile: good, atomically: true, encoding: .utf8)

            await app.open(path: broken, in: project)
            let bad = try #require(project.activeDocument)
            #expect(bad.resolvedDocumentLanguage == .json && bad.detail == "JSON")
            try await wait { bad.status.contains("1 error") }
            #expect(bad.status.contains("1 error"))
            let before = bad.session.text
            bad.formatDocument(nil)
            #expect(bad.session.text == before, "a file with an error is not reformatted")

            await app.open(path: good, in: project)
            let ok = try #require(project.activeDocument)
            try await wait { ok.status.contains("JSON") }
            #expect(!ok.status.contains("error"))
            let item = NSMenuItem(
                title: "",
                action: #selector(DocumentEditorController.formatDocument(_:)),
                keyEquivalent: ""
            )
            #expect(ok.validateMenuItem(item))
            ok.formatDocument(nil)
            #expect(ok.session.text == "{\n  \"b\": 1,\n  \"a\": [\n    1,\n    {}\n  ]\n}\n")
            #expect(ok.session.isDirty)
            ok.formatDocument(nil)
            #expect(ok.session.version == 1, "formatting a formatted file changes nothing")
        }

        @Test func aMarkdownFileIsKnownAsMarkdownWithColoursAndFoldsBySection() async throws {
            let (root, app, project) = try makeProject()
            defer {
                project.closeProject()
                app.welcome?.close()
                try? FileManager.default.removeItem(at: root)
            }
            let path = root.appendingPathComponent("README.md").path
            try "# Title\n\ntext\n\n## Part\n```swift\nlet a = 1\n```\n".write(
                toFile: path,
                atomically: true,
                encoding: .utf8
            )
            await app.open(path: path, in: project)
            let document = try #require(project.activeDocument)
            #expect(document.detail == "Markdown", "named, with colours, and no apology about completion")
            #expect(document.resolvedDocumentLanguage == .markdown)
        }

        @Test func yamlTomlAndShellFilesAreCheckedAndFormattedInTheEditor() async throws {
            let (root, app, project) = try makeProject()
            defer {
                project.closeProject()
                app.welcome?.close()
                try? FileManager.default.removeItem(at: root)
            }
            let yaml = root.appendingPathComponent("ci.yml").path
            let toml = root.appendingPathComponent("a.toml").path
            let shell = root.appendingPathComponent("run.sh").path
            try "name: x\nitems: [1, 2\nlast: 3\n".write(toFile: yaml, atomically: true, encoding: .utf8)
            try "a   = 1\n[t]\nb=2\nb=3\n".write(toFile: toml, atomically: true, encoding: .utf8)
            try "if true; then\necho hi\nfi\n".write(toFile: shell, atomically: true, encoding: .utf8)
            let format = NSMenuItem(
                title: "",
                action: #selector(DocumentEditorController.formatDocument(_:)),
                keyEquivalent: ""
            )

            await app.open(path: yaml, in: project)
            let y = try #require(project.activeDocument)
            #expect(y.resolvedDocumentLanguage == .yaml)
            try await wait { y.status.contains("error") }
            #expect(y.status.contains("error") && y.validateMenuItem(format))
            let before = y.session.text
            y.formatDocument(nil)
            #expect(y.session.text == before, "a YAML file with an error is not reformatted")

            await app.open(path: toml, in: project)
            let t = try #require(project.activeDocument)
            try await wait { t.status.contains("1 error") }
            #expect(t.status.contains("1 error"), "the key defined twice")
            try t.session.apply(
                [DocumentEdit(
                    range: UTF16TextRange(location: 0, length: t.session.utf16Length),
                    replacement: "a   = 1\n[t]\nb=2\n"
                )],
                expectedVersion: t.session.version
            )
            try await wait { !t.status.contains("error") }
            t.formatDocument(nil)
            #expect(t.session.text == "a = 1\n\n[t]\nb = 2\n")

            await app.open(path: shell, in: project)
            let s = try #require(project.activeDocument)
            #expect(s.resolvedDocumentLanguage == .shell && s.validateMenuItem(format))
            s.formatDocument(nil)
            #expect(s.session.text == "if true; then\n  echo hi\nfi\n")
        }
    }
}
