import AppKit
import EditorPlatformTextKit
import EditorUI
import Foundation
import IDEApplication
import IDEDomain
import IDETestSupport
import SyntaxInfrastructure
import Testing

/// A view whose colours are managed by the controller, as in a window: the path and the size of
/// the document decide whether there are any.
@MainActor
private final class ManagedScreen {
    let editor: TextKitEditor
    let session: DocumentSession
    let controller: SyntaxColouringController
    let scroll: NSScrollView
    let window: NSWindow

    init(_ text: String, path: String, policy: SyntaxPolicy) {
        let editor = TextKitEditorFactory.makeEditor(loadedText: text)
        self.editor = editor
        session = DocumentSession(path: path, backend: editor.backend)
        controller = SyntaxColouringController(
            session: session,
            source: editor.backend,
            policy: policy,
            makeHighlighter: { try? TreeSitterHighlighter() },
            present: { SyntaxPresenter(textView: editor.textView, coordinator: $0, policy: policy) }
        )
        scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        scroll.documentView = editor.textView
        window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = scroll
    }

    func render() -> NSBitmapImageRep {
        scroll.layoutSubtreeIfNeeded()
        let bitmap = scroll.bitmapImageRepForCachingDisplay(in: scroll.bounds)!
        scroll.cacheDisplay(in: scroll.bounds, to: bitmap)

        return bitmap
    }

    /// Draws until `condition` holds for the picture, then a few frames more.
    func settle(frames: Int = 400, until condition: (NSBitmapImageRep) -> Bool) async {
        for _ in 0..<frames {
            let picture = render()
            if condition(picture) { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        for _ in 0..<8 {
            _ = render()
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func insert(_ text: String, at location: Int) {
        editor.textView.insertText(text, replacementRange: NSRange(location: location, length: 0))
    }
}

private let code = """
import Foundation

struct Greeter {
    let name: String
    // say hello
    func greet() -> String { "Hello, \\(name)! 42" }
}

"""

private let smallLimit = SyntaxPolicy(maximumDocumentLength: 600)

@Test @MainActor
func aFileThatGrowsPastTheLimitLosesItsColoursOnScreen() async throws {
    let screen = ManagedScreen(code, path: "Main.swift", policy: smallLimit)
    await screen.settle { colourful($0) > 200 }
    #expect(colourful(screen.render()) > 200, "coloured while small")

    // A paste of ordinary lines: bigger than the limit, nothing coloured about it.
    screen.insert(String(repeating: "padding padding padding\n", count: 40), at: code.utf16.count)
    #expect(screen.controller.state == .off(.tooLarge))
    await screen.settle { colourful($0) == 0 }
    #expect(colourful(screen.render()) == 0, "the colours of the code that is still in view are gone")
}

@Test @MainActor
func savingASwiftFileAsTextClearsItsColoursOnScreen() async throws {
    let screen = ManagedScreen(code, path: "/w/Main.swift", policy: .standard)
    await screen.settle { colourful($0) > 200 }
    #expect(colourful(screen.render()) > 200)

    let store = MemoryDocumentFileStore()
    _ = try await SaveDocumentUseCase(store: store).saveAs(
        document: screen.session,
        to: "/w/Main.txt",
        target: .newFile,
        registry: DocumentRegistry()
    )
    screen.controller.refresh()
    #expect(screen.controller.state == .off(.languageNotSupported))
    await screen.settle { colourful($0) == 0 }
    #expect(colourful(screen.render()) == 0)
}

@Test @MainActor
func savingATextFileAsSwiftColoursItOnScreen() async throws {
    let screen = ManagedScreen(code, path: "/w/Notes.txt", policy: .standard)
    await screen.settle(frames: 30) { _ in false }
    #expect(colourful(screen.render()) == 0, "a text file is plain")

    _ = try await SaveDocumentUseCase(store: MemoryDocumentFileStore()).saveAs(
        document: screen.session,
        to: "/w/Notes.swift",
        target: .newFile,
        registry: DocumentRegistry()
    )
    screen.controller.refresh()
    #expect(screen.controller.state == .on)
    await screen.settle { colourful($0) > 200 }
    #expect(colourful(screen.render()) > 200)
}

@Test @MainActor
func aFileThatShrinksBackUnderTheLimitIsColouredAgain() async throws {
    let screen = ManagedScreen(code + String(repeating: "padding padding padding\n", count: 40), path: "Main.swift", policy: smallLimit)
    #expect(screen.controller.state == .off(.tooLarge), "it opened too large")
    await screen.settle(frames: 30) { _ in false }
    #expect(colourful(screen.render()) == 0)

    screen.editor.textView.insertText("", replacementRange: NSRange(location: code.utf16.count, length: screen.editor.textView.string.utf16.count - code.utf16.count))
    #expect(screen.controller.state == .on)
    await screen.settle { colourful($0) > 200 }
    #expect(colourful(screen.render()) > 200)
}
