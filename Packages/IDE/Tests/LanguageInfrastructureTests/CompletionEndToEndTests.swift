import AppKit
import EditorPlatformTextKit
@testable import EditorUI
import Foundation
import IDEApplication
import IDEDomain
import Testing
@testable import LanguageInfrastructure

// The whole chain on this machine: a real text view, the controller and list, the language
// services and the real SourceKit-LSP of the selected Xcode. They need that tool and the SwiftPM
// fixture of TK-009; without them they are not run.

private let fixture = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Fixtures/SwiftPMPackage")
private let mainFile = fixture.appendingPathComponent("Sources/App/main.swift")

private let toolAvailable: Bool = {
    guard FileManager.default.fileExists(atPath: mainFile.path) else { return false }

    let finder = Process()
    finder.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    finder.arguments = ["--find", "sourcekit-lsp"]
    finder.standardOutput = FileHandle.nullDevice
    finder.standardError = FileHandle.nullDevice

    return (try? finder.run()) != nil && { finder.waitUntilExit(); return finder.terminationStatus == 0 }()
}()

@MainActor
private struct Window {
    let editor: TextKitEditor
    let session: DocumentSession
    let nsWindow: NSWindow
    let coordinator: CompletionCoordinator
    var textView: NSTextView { editor.textView }

    init(text: String, path: String, untitled: Bool, services: LanguageServices) {
        editor = TextKitEditorFactory.makeEditor(loadedText: text)
        session = DocumentSession(path: path, backend: editor.backend, isUntitled: untitled)
        nsWindow = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 600, height: 400), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        nsWindow.contentView = EditorHostView(editor: editor)
        nsWindow.makeFirstResponder(editor.textView)
        coordinator = CompletionCoordinator(session: session, editor: editor, provider: services)
        editor.textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
    }

    func type(_ string: String) {
        textView.insertText(string, replacementRange: textView.selectedRange())
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.001))
    }

    func key(_ code: UInt16, characters: String) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown,
                         location: .zero,
                         modifierFlags: [],
                         timestamp: 0,
                         windowNumber: nsWindow.windowNumber,
                         context: nil,
                         characters: characters,
                         charactersIgnoringModifiers: characters,
                         isARepeat: false,
                         keyCode: code)!
    }
}

@MainActor
private func waitUntil(_ timeout: Duration = .seconds(90), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }

    return condition()
}

@MainActor
private func makeServices() -> (LanguageServices, URL) {
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("completion-e2e-\(UUID().uuidString)", isDirectory: true)

    return (LanguageServices(scratchRoot: scratch), scratch)
}

@Test(.enabled(if: toolAvailable)) @MainActor
func aDocumentWithNoFileGetsStandardLibraryCompletionFromTheRealServer() async throws {
    let (services, scratch) = makeServices()
    defer { services.terminateAll(); try? FileManager.default.removeItem(at: scratch) }
    let w = Window(text: "let s = \"abc\"\ns", path: "Untitled.swift", untitled: true, services: services)
    await services.attach(w.session)
    #expect(services.service(for: w.session)?.state == .running)

    w.type(".")
    #expect(await waitUntil { w.coordinator.controller.isShowing })
    #expect(w.coordinator.popup.isVisible)

    w.type("upp")
    #expect(await waitUntil { w.coordinator.controller.isShowing }, "still showing after narrowing")
    // Accept with Return.
    #expect(CompletionCoordinator.handle(w.key(36, characters: "\r"), controller: w.coordinator.controller))
    #expect(w.session.text == "let s = \"abc\"\ns.uppercased()")
    #expect(w.textView.selectedRange().location == (w.session.text as NSString).length, "after the parentheses of a call with no arguments")
}

@Test(.enabled(if: toolAvailable)) @MainActor
func aCallWithArgumentsGetsTheCaretBetweenItsParentheses() async throws {
    let (services, scratch) = makeServices()
    defer { services.terminateAll(); try? FileManager.default.removeItem(at: scratch) }
    let w = Window(text: "var s = \"abc\"\ns", path: "Untitled.swift", untitled: true, services: services)
    await services.attach(w.session)
    w.type(".")
    #expect(await waitUntil { w.coordinator.controller.isShowing })
    w.type("hasPre")
    #expect(await waitUntil { w.coordinator.controller.isShowing })
    #expect(CompletionCoordinator.handle(w.key(48, characters: "\t"), controller: w.coordinator.controller))
    #expect(w.session.text.hasSuffix("s.hasPrefix()"), "\(w.session.text.debugDescription)")
    #expect(w.textView.selectedRange().location == (w.session.text as NSString).length - 1)
}

@Test(.enabled(if: toolAvailable)) @MainActor
func aFileInAPackageSeesTheOtherFilesOfItsPackage() async throws {
    let (services, scratch) = makeServices()
    defer { services.terminateAll(); try? FileManager.default.removeItem(at: scratch) }
    let source = try String(contentsOf: mainFile, encoding: .utf8)
    let w = Window(text: source + "greeter", path: mainFile.path, untitled: false, services: services)
    await services.attach(w.session)
    #expect(services.service(for: w.session) != nil)
    #expect(services.runningRoots.map(\.lastPathComponent) == ["SwiftPMPackage"], "the server of the package, not the loose one")

    w.type(".")
    // A package is loaded the first time it is asked about, and a busy machine takes long over
    // it: the controller says "not ready" after ten seconds, and the user asks again.
    for _ in 0..<6 where !(await waitUntil(.seconds(15)) { w.coordinator.controller.isShowing }) {
        w.coordinator.controller.requestManually()
    }
    #expect(w.coordinator.controller.isShowing)
    w.type("greet")
    #expect(await waitUntil { w.coordinator.controller.isShowing })
    #expect(CompletionCoordinator.handle(w.key(36, characters: "\r"), controller: w.coordinator.controller))
    #expect(w.session.text.hasSuffix("greeter.greeting()"), "a member of Greeter, declared in another file of the package")
}

@Test(.enabled(if: toolAvailable)) @MainActor
func completionAskedByHandInTheMiddleOfAWordNarrowsToIt() async throws {
    let (services, scratch) = makeServices()
    defer { services.terminateAll(); try? FileManager.default.removeItem(at: scratch) }
    let w = Window(text: "let s = \"abc\"\ns.uppe", path: "Untitled.swift", untitled: true, services: services)
    await services.attach(w.session)
    w.coordinator.controller.requestManually()
    #expect(await waitUntil { w.coordinator.controller.isShowing })
    #expect(CompletionCoordinator.handle(w.key(36, characters: "\r"), controller: w.coordinator.controller))
    #expect(w.session.text.hasSuffix("s.uppercased()"), "the word typed so far was replaced, not appended to: \(w.session.text.debugDescription)")
}
