import AppKit
import IDEApplication
import Testing
@testable import WorkspaceUI

private struct FlatReader: ProjectDirectoryReading {
    func children(of path: String) async throws -> [ProjectFile] {
        path == "/w"
            ? [
                ProjectFile(path: "/w/Sources", isDirectory: true),
                ProjectFile(path: "/w/Package.swift", isDirectory: false)
            ]
            : []
    }
}

private final class RecordingItems: ProjectItemOperating, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [String] = []
    var recorded: [String] { lock.withLock { calls } }
    var failure: NewEntryError?

    func rename(_ path: String, to name: String) throws -> String {
        lock.withLock { calls.append("rename \(path) \(name)") }
        if let failure { throw failure }

        return (path as NSString).deletingLastPathComponent + "/" + name
    }

    func duplicate(_ path: String, as name: String) throws -> String {
        lock.withLock { calls.append("duplicate \(path) \(name)") }

        return (path as NSString).deletingLastPathComponent + "/" + name
    }

    func trash(_ path: String) throws { lock.withLock { calls.append("trash \(path)") } }

    func move(_ path: String, into directory: String) throws -> String {
        lock.withLock { calls.append("move \(path) \(directory)") }
        if let failure { throw failure }

        return directory + "/" + (path as NSString).lastPathComponent
    }

    func copy(_ path: String, into directory: String) throws -> String {
        lock.withLock { calls.append("copy \(path) \(directory)") }
        if let failure { throw failure }

        return directory + "/" + (path as NSString).lastPathComponent
    }
}

private final class RecordingCreator: ProjectEntryCreating, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [String] = []
    var recorded: [String] { lock.withLock { calls } }

    func create(_ kind: NewEntryKind, named name: String, in directory: String) throws -> String {
        lock.withLock { calls.append("\(kind) \(name) in \(directory)") }
        if name == "bad" { throw NewEntryError.alreadyExists("bad") }

        return directory + "/" + name
    }
}

@Suite(.serialized)
@MainActor
struct FilesContextMenuTests {
    private func makeController(creator: (any ProjectEntryCreating)?) async throws
        -> (ProjectFilesViewController, ProjectFiles, NSWindow) {
        _ = NSApplication.shared
        let model = ProjectFiles(root: "/w", reader: FlatReader(), creator: creator)
        let controller = ProjectFilesViewController(model: model)
        let window = NSWindow(
            contentRect: NSRect(x: -2000, y: -2000, width: 400, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        model.expand("/w")
        for _ in 0..<300 where controller.outline.numberOfRows < 3 { try await Task.sleep(for: .milliseconds(10)) }
        controller.pasteboard = NSPasteboard(name: NSPasteboard.Name("test-\(UUID().uuidString)"))

        return (controller, model, window)
    }

    private func menu(_ controller: ProjectFilesViewController, row: Int) -> NSMenu {
        controller.outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        let menu = NSMenu()
        controller.menuNeedsUpdate(menu)

        return menu
    }

    private func titles(_ menu: NSMenu) -> [String] { menu.items.filter { !$0.isSeparatorItem }.map(\.title) }

    @Test func aFileOffersNewOpenCopyPathsAndRevealAboveTheViewToggles() async throws {
        let (controller, _, window) = try await makeController(creator: RecordingCreator())
        defer {
            controller.disconnect()
            window.close()
        }
        let items = titles(menu(controller, row: 2))
        #expect(items.contains("Open") && items.contains("Copy Path") && items.contains("Reveal in Finder"))
        let kinds = menu(controller, row: 2).items.first?.submenu?.items.map(\.title)
        #expect(kinds == ["Swift File", "File", "Directory"])
        #expect(items.contains("Show Excluded") && items.last == "Refresh Files")
        let folder = titles(menu(controller, row: 1))
        #expect(!folder.contains("Open") && folder.first == "New")
    }

    @Test func aGitSubmenuShowsTheAppsEntriesAndRunsTheChosenOne() async throws {
        let (controller, _, window) = try await makeController(creator: nil)
        defer {
            controller.disconnect()
            window.close()
        }
        var asked: [String] = []
        var ran: [String] = []
        controller.gitEntries = { path in
            asked.append(path)

            return [
                .separator,
                .action(title: "Add", icon: nil, isEnabled: false) { ran.append("add") },
                .action(title: "Show Diff") { ran.append("diff") },
                .separator,
                .separator,
                .action(title: "Push…") { ran.append("push") },
                .separator
            ]
        }
        let git = try #require(menu(controller, row: 2).items.first { $0.title == "Git" }?.submenu)
        #expect(asked == ["/w/Package.swift"])
        #expect(
            git.items.map(\.title) == ["Add", "Show Diff", "", "Push…"],
            "separators are not doubled or left at the ends"
        )
        #expect(git.items[0].isEnabled == false && git.items[1].isEnabled)
        let diff = git.items[1]
        _ = NSApp.sendAction(try #require(diff.action), to: diff.target, from: diff)
        #expect(ran == ["diff"])
        controller.gitEntries = { _ in [] }
        #expect(!titles(menu(controller, row: 2)).contains("Git"))
    }

    private func makeEditable(_ items: RecordingItems) async throws
        -> (ProjectFilesViewController, ProjectFiles, NSWindow) {
        _ = NSApplication.shared
        let model = ProjectFiles(root: "/w", reader: FlatReader(), operations: items)
        let controller = ProjectFilesViewController(model: model)
        let window = NSWindow(
            contentRect: NSRect(x: -2000, y: -2000, width: 400, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        model.expand("/w")
        for _ in 0..<300 where controller.outline.numberOfRows < 3 { try await Task.sleep(for: .milliseconds(10)) }

        return (controller, model, window)
    }

    private func press(_ title: String, row: Int, in controller: ProjectFilesViewController) throws {
        let item = try #require(menu(controller, row: row).items.first { $0.title == title })
        _ = NSApp.sendAction(try #require(item.action), to: item.target, from: item)
    }

    @Test func renameDuplicateAndDeleteAreOfferedForItemsButNotTheRootOrWithoutOperations() async throws {
        let (controller, _, window) = try await makeEditable(RecordingItems())
        defer {
            controller.disconnect()
            window.close()
        }
        let items = titles(menu(controller, row: 2))
        #expect(items.contains("Rename…") && items.contains("Duplicate…") && items.contains("Delete…"))
        #expect(!titles(menu(controller, row: 0)).contains("Rename…"))
        let (plain, _, other) = try await makeController(creator: nil)
        defer {
            plain.disconnect()
            other.close()
        }
        #expect(!titles(menu(plain, row: 2)).contains("Rename…"))
    }

    @Test func renameAsksWithTheCurrentNameThenRenamesAndAFailureComesBackAsText() async throws {
        let items = RecordingItems()
        let (controller, _, window) = try await makeEditable(items)
        defer {
            controller.disconnect()
            window.close()
        }
        var prompts: [NamePrompt] = []
        var answers: [String?] = []
        controller.promptForName = { prompt, submit in
            prompts.append(prompt)
            answers.append(submit("Renamed.swift"))
        }
        try press("Rename…", row: 2, in: controller)
        #expect(prompts.first?.title == "Rename File" && prompts.first?.initialText == "Package.swift")
        #expect(prompts.first?.selectsBaseName == true && answers == [nil])
        #expect(items.recorded == ["rename /w/Package.swift Renamed.swift"])
        try press("Rename…", row: 1, in: controller)
        #expect(prompts.last?.title == "Rename Folder" && prompts.last?.selectsBaseName == false)
        items.failure = .alreadyExists("Renamed.swift")
        controller.promptForName = { _, submit in answers.append(submit("Renamed.swift")) }
        try press("Rename…", row: 2, in: controller)
        #expect(answers.last == "“Renamed.swift” already exists.")
    }

    @Test func duplicateSuggestsACopyNameAndOpensTheCopyOfAFile() async throws {
        let items = RecordingItems()
        let (controller, _, window) = try await makeEditable(items)
        defer {
            controller.disconnect()
            window.close()
        }
        var prompt: NamePrompt?
        var opened: [String] = []
        controller.openFile = { opened.append($0) }
        controller.promptForName = { asked, submit in
            prompt = asked
            _ = submit(asked.initialText)
        }
        try press("Duplicate…", row: 2, in: controller)
        #expect(prompt?.title == "Duplicate File" && prompt?.initialText == "Package copy.swift")
        #expect(items.recorded == ["duplicate /w/Package.swift Package copy.swift"])
        #expect(opened == ["/w/Package copy.swift"])
    }

    @Test func deleteAsksFirstWarnsAboutUnsavedFilesAndOnlyThenTrashes() async throws {
        let items = RecordingItems()
        let (controller, model, window) = try await makeEditable(items)
        defer {
            controller.disconnect()
            window.close()
        }
        model.unsavedPaths = ["/w/Package.swift"]
        var asked: [(String, String)] = []
        var answer = false
        controller.confirmTrash = { title, message, completion in
            asked.append((title, message))
            completion(answer)
        }
        try press("Delete…", row: 2, in: controller)
        #expect(asked.first?.0 == "Delete “Package.swift”?" && asked.first?.1
            .contains("One open file has changes") == true)
        #expect(items.recorded.isEmpty, "a refusal deletes nothing")
        answer = true
        try press("Delete…", row: 2, in: controller)
        #expect(items.recorded == ["trash /w/Package.swift"])
    }

    private func editable(_ items: RecordingItems) async throws -> (ProjectFilesViewController, NSWindow) {
        let (controller, _, window) = try await makeEditable(items)
        controller.pasteboard = NSPasteboard(name: NSPasteboard.Name("test-\(UUID().uuidString)"))
        controller.reportFailure = { _ in }

        return (controller, window)
    }

    @Test func theMenuOffersCutCopyAndPasteWithPasteDimmedUntilThereAreFiles() async throws {
        let (controller, window) = try await editable(RecordingItems())
        defer {
            controller.disconnect()
            window.close()
        }
        let file = menu(controller, row: 2)
        #expect(
            titles(file).prefix(6) == ["Cut", "Copy", "Copy Path", "Copy Relative Path", "Paste", "Open"],
            "no New without a creator"
        )
        #expect(file.items.first { $0.title == "Paste" }?.isEnabled == false)
        #expect(file.items.first { $0.title == "Cut" }?.keyEquivalent == "x")
        let root = titles(menu(controller, row: 0))
        #expect(!root.contains("Cut") && !root.contains("Copy") && root.contains("Paste"))
    }

    @Test func copyPutsTheFileOnThePasteboardAndPasteCopiesItIntoTheFolderOfTheSelection() async throws {
        let items = RecordingItems()
        let (controller, window) = try await editable(items)
        defer {
            controller.disconnect()
            window.close()
        }
        try press("Copy", row: 2, in: controller)
        let urls = controller.pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]
        #expect(urls?.map(\.path) == ["/w/Package.swift"])
        #expect(controller.canPaste)
        try press("Paste", row: 1, in: controller)
        #expect(items.recorded == ["copy /w/Package.swift /w/Sources"])
        controller.outline.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
        controller.pasteIntoSelection()
        #expect(items.recorded.last == "copy /w/Package.swift /w", "a file's folder is where it goes")
    }

    @Test func cutThenPasteMovesOnceAndALaterCopyOfThePasteboardIsACopy() async throws {
        let items = RecordingItems()
        let (controller, window) = try await editable(items)
        defer {
            controller.disconnect()
            window.close()
        }
        try press("Cut", row: 2, in: controller)
        try press("Paste", row: 1, in: controller)
        #expect(items.recorded == ["move /w/Package.swift /w/Sources"])
        try press("Paste", row: 1, in: controller)
        #expect(items.recorded.last == "copy /w/Package.swift /w/Sources", "the cut was used up")
        try press("Cut", row: 2, in: controller)
        controller.pasteboard.clearContents()
        controller.pasteboard.writeObjects([URL(fileURLWithPath: "/elsewhere/other.txt") as NSURL])
        try press("Paste", row: 1, in: controller)
        #expect(items.recorded.last == "copy /elsewhere/other.txt /w/Sources", "another copy replaced the cut")
    }

    @Test func theResponderChainCommandsActOnTheSelectedItemAndAreValidated() async throws {
        let items = RecordingItems()
        let (controller, window) = try await editable(items)
        defer {
            controller.disconnect()
            window.close()
        }
        controller.outline.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
        let copy = NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "")
        let paste = NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "")
        #expect(controller.outline.validateUserInterfaceItem(copy) && !controller.outline
            .validateUserInterfaceItem(paste))
        controller.outline.copy(nil)
        #expect(controller.outline.validateUserInterfaceItem(paste))
        controller.outline.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        controller.outline.paste(nil)
        #expect(items.recorded == ["copy /w/Package.swift /w/Sources"])
        controller.outline.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        #expect(!controller.outline.validateUserInterfaceItem(copy), "the project folder itself is not copied")
    }

    @Test func draggingMovesInsideTheTreeCopiesFromOutsideAndNeverIntoItself() async throws {
        let items = RecordingItems()
        let (controller, window) = try await editable(items)
        defer {
            controller.disconnect()
            window.close()
        }
        let folder = try #require(controller.outline.item(atRow: 1))
        let file = try #require(controller.outline.item(atRow: 2))
        let package = URL(fileURLWithPath: "/w/Package.swift"), sources = URL(fileURLWithPath: "/w/Sources")
        #expect(controller.dropOperation(for: [package], onto: folder, isInternal: true, copying: false)
            .operation == .move)
        #expect(controller.dropOperation(for: [package], onto: folder, isInternal: true, copying: true)
            .operation == .copy)
        #expect(controller.dropOperation(for: [package], onto: folder, isInternal: false, copying: false)
            .operation == .copy)
        #expect(controller.dropOperation(for: [sources], onto: folder, isInternal: true, copying: false).operation
            .isEmpty)
        #expect(controller.dropOperation(for: [], onto: folder, isInternal: true, copying: false).operation.isEmpty)
        let onFile = controller.dropOperation(for: [sources], onto: file, isInternal: true, copying: false)
        #expect(onFile.target?.path == "/w" && onFile.operation == .move, "a file under the pointer means its folder")
        #expect(controller.performDrop(of: [package], onto: folder, isInternal: true, copying: false))
        #expect(controller.performDrop(
            of: [URL(fileURLWithPath: "/elsewhere/x.txt")],
            onto: nil,
            isInternal: false,
            copying: false
        ))
        #expect(items.recorded == ["move /w/Package.swift /w/Sources", "copy /elsewhere/x.txt /w"])
        #expect(!controller.performDrop(of: [sources], onto: folder, isInternal: true, copying: false))
    }

    @Test func aFailedPasteOrDropIsReported() async throws {
        let items = RecordingItems()
        let (controller, window) = try await editable(items)
        defer {
            controller.disconnect()
            window.close()
        }
        var reported: [String] = []
        controller.reportFailure = { reported.append($0) }
        items.failure = .alreadyExists("Package.swift")
        try press("Copy", row: 2, in: controller)
        try press("Paste", row: 1, in: controller)
        let folder = try #require(controller.outline.item(atRow: 1))
        #expect(!controller.performDrop(
            of: [URL(fileURLWithPath: "/w/Package.swift")],
            onto: folder,
            isInternal: true,
            copying: false
        ))
        #expect(reported == ["“Package.swift” already exists.", "“Package.swift” already exists."])
    }

    @Test func withoutACreatorThereIsNoNewItemAndTheRootOffersNoRelativePath() async throws {
        let (controller, _, window) = try await makeController(creator: nil)
        defer {
            controller.disconnect()
            window.close()
        }
        #expect(!titles(menu(controller, row: 2)).contains("New"))
        #expect(!titles(menu(controller, row: 0)).contains("Copy Relative Path"))
    }

    @Test func copyPathPutsTheAbsoluteOrRelativePathOnThePasteboard() async throws {
        let (controller, _, window) = try await makeController(creator: nil)
        defer {
            controller.disconnect()
            window.close()
        }
        let file = menu(controller, row: 2)
        let copy = try #require(file.items.first { $0.title == "Copy Path" })
        _ = NSApp.sendAction(try #require(copy.action), to: copy.target, from: copy)
        #expect(controller.pasteboard.string(forType: .string) == "/w/Package.swift")
        let relative = try #require(file.items.first { $0.title == "Copy Relative Path" })
        _ = NSApp.sendAction(try #require(relative.action), to: relative.target, from: relative)
        #expect(controller.pasteboard.string(forType: .string) == "Package.swift")
    }

    private func choose(_ title: String, row: Int, in controller: ProjectFilesViewController) throws {
        let new = try #require(menu(controller, row: row).items.first { $0.title == "New" }?.submenu)
        let item = try #require(new.items.first { $0.title == title })
        _ = NSApp.sendAction(try #require(item.action), to: item.target, from: item)
    }

    @Test func eachNewKindAsksWithItsOwnTitleCreatesInTheClickedFolderAndOpensFiles() async throws {
        let creator = RecordingCreator()
        let (controller, _, window) = try await makeController(creator: creator)
        defer {
            controller.disconnect()
            window.close()
        }
        var asked: [NamePrompt] = []
        var opened: [String] = []
        controller.promptForName = { prompt, submit in
            asked.append(prompt)
            #expect(submit("Main") == nil)
        }
        controller.openFile = { opened.append($0) }
        try choose("Swift File", row: 1, in: controller)
        try choose("File", row: 1, in: controller)
        try choose("Directory", row: 1, in: controller)
        #expect(asked.map(\.title) == ["New Swift File", "New File", "New Directory"])
        #expect(asked.map(\.icon) == ["swift", "doc.text", "folder"])
        #expect(creator.recorded == [
            "swiftFile Main in /w/Sources",
            "file Main in /w/Sources",
            "folder Main in /w/Sources"
        ])
        #expect(opened == ["/w/Sources/Main", "/w/Sources/Main"], "files open, a directory does not")
    }

    @Test func aFailureComesBackAsTheMessageForTheBoxAndAFileClickUsesItsFolder() async throws {
        let creator = RecordingCreator()
        let (controller, _, window) = try await makeController(creator: creator)
        defer {
            controller.disconnect()
            window.close()
        }
        var answers: [String?] = []
        controller.promptForName = { _, submit in answers.append(submit("bad")) }
        try choose("File", row: 2, in: controller)
        #expect(answers == ["“bad” already exists."])
        #expect(creator.recorded == ["file bad in /w"], "a file's New goes into the folder it is in")
    }
}

@Suite(.serialized)
@MainActor
struct NamePromptPanelTests {
    private func make(
        _ submit: @escaping (String) -> String?
    ) -> (NamePromptPanel, NSWindow, () -> Int) {
        _ = NSApplication.shared
        let parent = NSWindow(
            contentRect: NSRect(x: -2000, y: -2000, width: 600, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        parent.isReleasedWhenClosed = false
        var closed = 0
        let panel = NamePromptPanel(prompt: NamePrompt(title: "New File"), over: parent, submit: submit) { closed += 1 }

        return (panel, parent, { closed })
    }

    @Test func returnSubmitsAcceptedNamesAndClosesTheBox() {
        var seen: [String] = []
        let (panel, parent, closed) = make {
            seen.append($0)

            return nil
        }
        panel.show()
        #expect(panel.window.isVisible && parent.childWindows?.contains(panel.window) == true)
        panel.field.stringValue = "Main.swift"
        #expect(panel.control(
            panel.field,
            textView: NSTextView(),
            doCommandBy: #selector(NSResponder.insertNewline(_:))
        ))
        #expect(seen == ["Main.swift"] && !panel.window.isVisible && closed() == 1)
        panel.commit()
        #expect(seen.count == 1 && closed() == 1, "a closed box submits nothing more")
        parent.close()
    }

    @Test func aRefusalStaysOpenShowsItsMessageAndClearsWhenTheNameChanges() {
        let (panel, parent, closed) = make { $0 == "ok" ? nil : "“\($0)” already exists." }
        panel.show()
        panel.field.stringValue = "taken"
        panel.commit()
        #expect(panel.window.isVisible && panel.errorMessage == "“taken” already exists." && closed() == 0)
        panel.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        #expect(panel.errorMessage == nil)
        panel.field.stringValue = "ok"
        panel.commit()
        #expect(!panel.window.isVisible && closed() == 1)
        parent.close()
    }

    @Test func escapeCancelsWithoutSubmitting() {
        var submitted = false
        let (panel, parent, closed) = make { _ in
            submitted = true

            return nil
        }
        panel.show()
        #expect(panel.control(
            panel.field,
            textView: NSTextView(),
            doCommandBy: #selector(NSResponder.cancelOperation(_:))
        ))
        #expect(!submitted && !panel.window.isVisible && closed() == 1)
        #expect(!panel.control(
            panel.field,
            textView: NSTextView(),
            doCommandBy: #selector(NSResponder.deleteBackward(_:))
        ))
        parent.close()
    }
}
