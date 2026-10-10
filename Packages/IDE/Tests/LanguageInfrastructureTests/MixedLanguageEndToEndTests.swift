import AppKit
@testable import EditorPlatformTextKit
import EditorUI
import Foundation
import IDEApplication
import IDEDomain
import IDETestSupport
import Testing
@testable import LanguageInfrastructure

// The C family through the real SourceKit-LSP of the selected Xcode, which hands it to its clangd
// (TK-017, first slice): completion in C, C++ and Objective-C files of a SwiftPM package, and
// across languages from Swift. The package is copied to a temporary folder and built there, so that
// nothing is written into the repository, in a folder the server accepts (not the system's temporary
// folder). The build matters: without it the server has no compile
// flags for the C family, so headers are not found and types from them are unknown (see
// `cFamilyWithoutABuildDoesNotKnowThePackagesHeaders`).

private let fixture = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Fixtures/SwiftPMMixed")

private let toolsAvailable: Bool = {
    guard FileManager.default.fileExists(atPath: fixture.appendingPathComponent("Package.swift").path) else { return false }

    for tool in ["sourcekit-lsp", "clangd"] {
        let finder = Process()
        finder.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        finder.arguments = ["--find", tool]
        finder.standardOutput = FileHandle.nullDevice
        finder.standardError = FileHandle.nullDevice
        guard (try? finder.run()) != nil else { return false }

        finder.waitUntilExit()
        guard finder.terminationStatus == 0 else { return false }
    }

    return true
}()

/// `Packages/IDE/.build`: ignored by git, and a place whose compile flags the server accepts.
private let packageBuildFolder = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent(".build", isDirectory: true)

@MainActor
private struct WindowFixture {
    let editor: TextKitEditor
    let session: DocumentSession
    let window: NSWindow
    let host: EditorHostView
    let coordinator: LanguageFeaturesCoordinator
    let text: String
    let opened = Opened()
    var textView: NSTextView { editor.textView }

    @MainActor final class Opened { var places: [DefinitionLocation] = [] }

    func point(ofCharacter index: Int) -> NSPoint {
        let screen = textView.firstRect(forCharacterRange: NSRange(location: index, length: 1), actualRange: nil)
        let box = textView.convert(window.convertFromScreen(screen), from: nil)

        return NSPoint(x: box.midX, y: box.midY)
    }

    func commandClick(at index: Int) -> Bool {
        let event = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: textView.convert(point(ofCharacter: index), to: nil),
            modifierFlags: .command,
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!

        // swiftlint:disable:next force_cast
        return (textView as! CodeTextView).handleCommandClick(event)
    }
}

/// One built copy of the package for the whole run: a copy and a build per test would be most of the time.
/// It is made fresh at the first use of each run and left in `Packages/IDE/.build` (ignored by git).
private enum SharedPackage {
    static let result: Result<URL, any Error> = Result {
        let base = packageBuildFolder.appendingPathComponent("e2e-mixed", isDirectory: true).resolvingSymlinksInPath()
        try? FileManager.default.removeItem(at: base)
        let root = base.appendingPathComponent("Mixed", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture, to: root)
        try? FileManager.default.removeItem(at: root.appendingPathComponent(".build"))
        try build(root)

        return root
    }

    /// Builds with SwiftPM, as the user's Build would, so that the server has compile flags.
    static func build(_ root: URL) throws {
        let build = Process()
        build.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        build.arguments = ["swift", "build", "-j", "2", "--package-path", root.path]
        build.standardOutput = FileHandle.nullDevice
        build.standardError = FileHandle.nullDevice
        try build.run()
        build.waitUntilExit()
        struct BuildFailed: Error {}
        guard build.terminationStatus == 0 else { throw BuildFailed() }
    }
}

@MainActor
private final class Package {
    let root: URL
    let services: LanguageServices
    private let scratch: URL

    /// The shared built copy.
    func built() throws -> Package { self }

    /// A copy that is not built: for the test of what the server does without a build.
    init(unbuilt: Bool = false) throws {
        let scratchBase = packageBuildFolder.appendingPathComponent("e2e-scratch-\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath()
        scratch = scratchBase
        if unbuilt {
            // Not under the system's temporary folder: from there clangd gets no compile flags (see ADR-026).
            let base = packageBuildFolder.appendingPathComponent("e2e-unbuilt-\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath()
            root = base.appendingPathComponent("Mixed", isDirectory: true)
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: fixture, to: root)
            try? FileManager.default.removeItem(at: root.appendingPathComponent(".build"))
        } else {
            root = try SharedPackage.result.get()
        }

        services = LanguageServices(scratchRoot: scratch)
        self.unbuilt = unbuilt
    }

    private let unbuilt: Bool

    deinit {
        MainActor.assumeIsolated { services.terminateAll() }
        try? FileManager.default.removeItem(at: scratch)
        if unbuilt { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    }

    /// The labels of the completion at the end of `tail`, which is added to the file at its end, or
    /// before the last `marker` (`@end`, say) with `after` following it; asked again until `enough` is
    /// satisfied: the first answers after a file is opened can still come from fallback flags, before
    /// the package's build settings reach clangd. The last labels if time runs out.
    func labels(
        file: String,
        tail: String,
        after: String = "",
        before marker: String? = nil,
        timeout: Duration = .seconds(90),
        until enough: ([String]) -> Bool = { !$0.isEmpty }
    ) async throws -> [String] {
        let path = root.appendingPathComponent(file).path
        var text = try String(contentsOfFile: path, encoding: .utf8)
        let caret: Int
        if let marker, let range = text.range(of: marker, options: .backwards) {
            let start = text.utf16.distance(from: text.utf16.startIndex, to: range.lowerBound)
            text.insert(contentsOf: tail + after, at: range.lowerBound)
            caret = start + tail.utf16.count
        } else {
            text += tail + after
            caret = text.utf16.count - after.utf16.count
        }

        let session = DocumentSession(path: path, backend: StringDocumentBackend(loadedText: text))
        await services.attach(session)
        defer { services.detach(session) }

        let deadline = ContinuousClock.now + timeout
        var last: [String] = []
        while ContinuousClock.now < deadline {
            if case .items(let items, _) = await services.completion(for: session, caret: { caret }) {
                last = items.map(\.label)
                if enough(last) { return last }
            }

            try await Task.sleep(for: .milliseconds(200))
        }

        return last
    }

    /// A document of the package, with `tail` added at its end, given to the server.
    func open(_ file: String, tail: String = "") async throws -> (session: DocumentSession, text: String) {
        let path = root.appendingPathComponent(file).path
        let text = try String(contentsOfFile: path, encoding: .utf8) + tail
        let session = DocumentSession(path: path, backend: StringDocumentBackend(loadedText: text))
        await services.attach(session)

        return (session, text)
    }

    /// The UTF-16 offset `inside` characters into the `occurrence`-th `token` of `text`.
    func offset(of token: String, in text: String, occurrence: Int = 1, inside: Int = 1) throws -> Int {
        var from = text.startIndex
        var found: Range<String.Index>?
        for _ in 0..<occurrence {
            found = text.range(of: token, range: from..<text.endIndex)
            guard let found else { break }

            from = found.upperBound
        }
        let range = try #require(found, "\(token) is not in the text")

        return text.utf16.distance(from: text.utf16.startIndex, to: range.lowerBound) + inside
    }

    /// Asks `ask` again until `enough` is satisfied by the answer (the first answers after a file is
    /// opened can still come before the package's flags): the last answer if time runs out.
    func eventually<T: Sendable>(
        _ timeout: Duration = .seconds(90),
        ask: () async -> T,
        until enough: (T) -> Bool
    ) async throws -> T {
        let deadline = ContinuousClock.now + timeout
        var last = await ask()
        while !enough(last), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(200))
            last = await ask()
        }

        return last
    }

    func hover(_ session: DocumentSession, at offset: Int, until enough: (String?) -> Bool = { $0 != nil }) async throws -> String? {
        try await eventually(ask: {
            if case .content(let content) = await services.hover(for: session, offset: { offset }) { return content.text }

            return nil
        }, until: enough)
    }

    func definition(_ session: DocumentSession, at offset: Int, until enough: ([DefinitionLocation]) -> Bool = { !$0.isEmpty }) async throws -> [DefinitionLocation] {
        try await eventually(ask: {
            if case .locations(let found) = await services.definition(for: session, offset: { offset }) { return found }

            return []
        }, until: enough)
    }

    func diagnostics(_ session: DocumentSession, until enough: (DocumentDiagnostics?) -> Bool) async throws -> DocumentDiagnostics? {
        try await eventually(ask: { services.diagnostics(for: session) }, until: enough)
    }

    /// A real text view in a window over a document of the package, with the coordinator of the
    /// language features connected to the package's servers.
    func window(_ file: String, tail: String = "") async throws -> WindowFixture {
        let path = root.appendingPathComponent(file).path
        let text = try String(contentsOfFile: path, encoding: .utf8) + tail
        let editor = TextKitEditorFactory.makeEditor(loadedText: text)
        let session = DocumentSession(path: path, backend: editor.backend)
        let lineIndex = DocumentLineIndex(session: session, source: editor.backend)
        let host = EditorHostView(editor: editor, lineIndex: lineIndex)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 900, height: 600), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        window.makeFirstResponder(editor.textView)
        await services.attach(session)
        let coordinator = LanguageFeaturesCoordinator(session: session, editor: editor, host: host, lineIndex: lineIndex, provider: services)
        let fixture = WindowFixture(editor: editor, session: session, window: window, host: host, coordinator: coordinator, text: text)
        coordinator.openLocation = { [fixture] in fixture.opened.places.append($0) }
        window.layoutIfNeeded()

        return fixture
    }
}

// One package copy and one server at a time: each is a build and a language server on an 8 GB machine.
@Suite(.serialized, .enabled(if: toolsAvailable))
struct MixedLanguageEndToEnd {
    @Test @MainActor
    func aCFileOfAPackageGetsItsOwnFunctionsAndTypes() async throws {
        let package = try Package().built()
        let names = try await package.labels(file: "Sources/CLib/clib.c", tail: "\nvoid probe(clib_point p) { clib_") { $0.contains { $0.hasPrefix("clib_length") } && $0.contains("clib_point") }
        #expect(names.contains { $0.hasPrefix("clib_add") } && names.contains { $0.hasPrefix("clib_length") } && names.contains("clib_point"), "\(names)")
        #expect(names.allSatisfy { !$0.hasPrefix(" ") }, "clangd's marker space is not shown")
    }

    @Test @MainActor
    func aCStructHasItsMembers() async throws {
        let package = try Package().built()
        let names = try await package.labels(file: "Sources/CLib/clib.c", tail: "\nvoid probe(clib_point p) { p.") { Set($0) == ["x", "y"] }
        #expect(Set(names) == ["x", "y"], "\(names)")
    }

    @Test @MainActor
    func aCppFileGetsTheMembersOfItsClass() async throws {
        let package = try Package().built()
        let names = try await package.labels(file: "Sources/CxxLib/cxxlib.cpp", tail: "\nvoid probe() { cxxlib::Greeter g(\"x\"); g.") { $0.contains { $0.hasPrefix("greetings") } }
        #expect(names.contains { $0.hasPrefix("greeting") } && names.contains { $0.hasPrefix("greetings") }, "\(names)")
    }

    @Test @MainActor
    func anObjectiveCFileGetsItsMessagesAndItsClass() async throws {
        let package = try Package().built()
        let names = try await package.labels(file: "Sources/ObjCLib/ObjCGreeter.m", tail: "- (void)probe { [self gre", after: "] }\n\n", before: "@end") { $0.contains { $0.hasPrefix("greetingForTimes") } }
        #expect(names.contains { $0.hasPrefix("greetingForTimes") }, "\(names)")
    }

    @Test @MainActor
    func swiftSeesTheCAndObjectiveCTargetsOfThePackage() async throws {
        let package = try Package().built()
        let fromC = try await package.labels(file: "Sources/App/main.swift", tail: "\nlet more = clib_") { $0.contains { $0.hasPrefix("clib_length") } }
        #expect(fromC.contains { $0.hasPrefix("clib_add") } && fromC.contains { $0.hasPrefix("clib_length") }, "\(fromC)")

        let fromObjC = try await package.labels(file: "Sources/App/main.swift", tail: "\nlet more2 = greeter.") { $0.contains { $0.hasPrefix("greeting(forTimes") } }
        #expect(fromObjC.contains { $0.hasPrefix("greeting(forTimes") }, "\(fromObjC)")
    }

    @Test @MainActor
    func aDocumentWithNoFileIsServedInTheLanguageItIsChosenAs() async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("untitled-c-\(UUID().uuidString)", isDirectory: true)
        let languages = DocumentLanguages()
        let services = LanguageServices(scratchRoot: scratch, languages: languages)
        defer { services.terminateAll(); try? FileManager.default.removeItem(at: scratch) }

        let text = "#include <stdio.h>\nstruct point { int x; int y; };\nvoid f(struct point p) { p."
        let session = DocumentSession(path: "Untitled.swift", backend: StringDocumentBackend(loadedText: text), isUntitled: true)
        languages.selector(for: session).setOverride(.c)
        await services.attach(session)

        let caret = text.utf16.count
        var names: [String] = []
        for _ in 0..<900 where names.isEmpty {
            if case .items(let items, _) = await services.completion(for: session, caret: { caret }) { names = items.map(\.label) }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(Set(names).isSuperset(of: ["x", "y"]), "\(names)")
        #expect(services.service(for: session)?.sync.uri(of: session)?.hasSuffix(".c") == true, "the stand-in file has a C name")
    }

    @Test @MainActor
    func cFamilyWithoutABuildDoesNotKnowThePackagesHeaders() async throws {
        // Recorded as a fact about the server, not as wanted behaviour: with no build there are no compile
        // flags, so `clib.h` (in `include/`) is not found and `clib_point` is an unknown name.
        let package = try Package(unbuilt: true)
        let names = try await package.labels(file: "Sources/CLib/clib.c", tail: "\nvoid probe(clib_point p) { clib_", timeout: .seconds(20))
        #expect(!names.contains("clib_point"), "\(names)")
        #expect(names.contains { $0.hasPrefix("clib_length(int point") }, "the parameter type fell back to int: \(names)")
    }

    // MARK: Hover, definition, diagnostics

    @Test @MainActor
    func hoverTellsWhatAFunctionOfACTargetIs() async throws {
        let package = try Package().built()
        let (session, text) = try await package.open("Sources/App/main.swift")
        defer { package.services.detach(session) }

        let hover = try await package.hover(session, at: try package.offset(of: "clib_add", in: text)) { $0?.contains("clib_add") == true }
        #expect(hover?.contains("clib_add") == true, "\(String(describing: hover))")
    }

    @Test @MainActor
    func definitionOfACFunctionCalledFromSwiftIsItsDeclarationInTheHeader() async throws {
        let package = try Package().built()
        let (session, text) = try await package.open("Sources/App/main.swift")
        defer { package.services.detach(session) }

        let found = try await package.definition(session, at: try package.offset(of: "clib_add", in: text))
        let header = try String(contentsOf: package.root.appendingPathComponent("Sources/CLib/include/clib.h"), encoding: .utf8)
        let line = header.components(separatedBy: "\n").firstIndex { $0.contains("int clib_add") }
        let location = try #require(found.first, "\(found)")
        // The server names the header as the module map does ("CLib.h"); the file is "clib.h" on a
        // case-insensitive volume.
        #expect(location.path.lowercased().hasSuffix("sources/clib/include/clib.h") && location.line == line, "\(location)")
        #expect(location.offset == nil, "another file: no offset in this document")
    }

    @Test @MainActor
    func definitionOfAnObjectiveCMethodCalledFromSwiftIsInItsHeader() async throws {
        let package = try Package().built()
        let (session, text) = try await package.open("Sources/App/main.swift")
        defer { package.services.detach(session) }

        let found = try await package.definition(session, at: try package.offset(of: "greeting(forTimes", in: text))
        #expect(found.contains { $0.path.lowercased().hasSuffix("sources/objclib/include/objclib.h") }, "\(found)")
    }

    @Test @MainActor
    func definitionInTheSameDocumentCarriesAnOffset() async throws {
        let package = try Package().built()
        let (session, text) = try await package.open("Sources/App/main.swift")
        defer { package.services.detach(session) }

        // `total` in print(total, …) is defined by `let total` in the same file.
        let use = try package.offset(of: "total", in: text, occurrence: 2)
        let found = try await package.definition(session, at: use)
        let definition = try package.offset(of: "total", in: text, occurrence: 1, inside: 0)
        #expect(found.first?.offset == definition && found.first?.path == session.path, "\(found)")
    }

    @Test @MainActor
    func hoverAndDefinitionInACFile() async throws {
        let package = try Package().built()
        let (session, text) = try await package.open("Sources/CLib/clib.c", tail: "\nint probe(void) { return clib_add(1, 2); }\n")
        defer { package.services.detach(session) }

        let call = try package.offset(of: "clib_add(1", in: text)
        let hover = try await package.hover(session, at: call) { $0?.contains("clib_add") == true }
        #expect(hover?.contains("clib_add") == true, "\(String(describing: hover))")
        let found = try await package.definition(session, at: call)
        #expect(found.contains { $0.path.hasSuffix("clib.h") || $0.path.hasSuffix("clib.c") }, "\(found)")
    }

    @Test @MainActor
    func aSwiftErrorIsReportedWithItsPlaceInTheText() async throws {
        let package = try Package().built()
        let (session, text) = try await package.open("Sources/App/main.swift", tail: "\nlet bad: Int = \"text\"\n")
        defer { package.services.detach(session) }

        let report = try await package.diagnostics(session) { $0?.items.contains { $0.severity == .error } == true }
        let error = try #require(report?.items.first { $0.severity == .error }, "\(String(describing: report))")
        let literal = try package.offset(of: "\"text\"", in: text, inside: 0)
        #expect(error.range.location <= literal && error.range.location + error.range.length >= literal, "\(error)")
        #expect(report?.isVerified == false, "SourceKit-LSP names no version")
        #expect(report?.version == session.version)
    }

    @Test @MainActor
    func aCErrorIsReportedToo() async throws {
        let package = try Package().built()
        let (session, text) = try await package.open("Sources/CLib/clib.c", tail: "\nint bad = ;\n")
        defer { package.services.detach(session) }

        let report = try await package.diagnostics(session) { $0?.items.contains { $0.severity == .error } == true }
        let error = try #require(report?.items.first { $0.severity == .error }, "\(String(describing: report))")
        let line = try package.offset(of: "int bad", in: text, inside: 0)
        #expect(error.range.location >= line && error.range.location <= line + 12, "\(error)")
    }

    @Test @MainActor
    func aCommandClickOnACFunctionInSwiftOpensItsHeaderThroughTheWindow() async throws {
        let package = try Package().built()
        let w = try await package.window("Sources/App/main.swift")
        defer { package.services.detach(w.session) }

        let offset = try package.offset(of: "clib_add", in: w.text)
        #expect(w.commandClick(at: offset))
        _ = try await package.eventually(ask: { w.opened.places }, until: { !$0.isEmpty })
        let place = try #require(w.opened.places.first)
        #expect(place.path.lowercased().hasSuffix("sources/clib/include/clib.h"), "\(place)")
    }

    @Test @MainActor
    func theKeyAsksForTheDescriptionAtTheCaretThroughTheWindow() async throws {
        let package = try Package().built()
        let w = try await package.window("Sources/App/main.swift")
        defer { package.services.detach(w.session) }

        w.textView.setSelectedRange(NSRange(location: try package.offset(of: "clib_add", in: w.text), length: 0))
        let shown = try await package.eventually(ask: { () -> String? in
            w.coordinator.showQuickHelp()
            try? await Task.sleep(for: .milliseconds(400))

            return w.coordinator.popup.isVisible ? w.coordinator.popup.text : nil
        }, until: { $0?.contains("clib_add") == true })
        #expect(shown?.contains("clib_add") == true, "\(String(describing: shown))")
    }

    @Test @MainActor
    func anErrorIsCountedAndMarkedInTheMarginThroughTheWindow() async throws {
        let package = try Package().built()
        let w = try await package.window("Sources/App/main.swift", tail: "\nlet bad: Int = \"text\"\n")
        defer { package.services.detach(w.session) }

        let summary = try await package.eventually(ask: { w.coordinator.diagnostics.summary }, until: { $0.errors > 0 })
        #expect(summary.errors >= 1 && summary.text?.contains("error") == true, "\(summary)")
        let badLine = w.text.components(separatedBy: "\n").firstIndex { $0.hasPrefix("let bad") }
        #expect(w.host.lineNumberRuler?.problemLines[badLine ?? -1] == .error, "\(String(describing: w.host.lineNumberRuler?.problemLines))")
    }

    @Test @MainActor
    func definitionOfAnSDKSymbolIsAGeneratedInterfaceFileThatCanBeOpened() async throws {
        let package = try Package().built()
        let (session, text) = try await package.open("Sources/App/main.swift")
        defer { package.services.detach(session) }

        let found = try await package.definition(session, at: try package.offset(of: "print", in: text))
        let place = try #require(found.first, "\(found)")
        #expect(place.path.contains("/sourcekit-lsp/GeneratedInterfaces/") && place.path.hasSuffix(".swiftinterface"), "\(place)")
        #expect(FileManager.default.fileExists(atPath: place.path) && place.offset == nil)
    }
}
