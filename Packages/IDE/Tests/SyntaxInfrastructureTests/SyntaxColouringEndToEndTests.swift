import AppKit
import EditorPlatformTextKit
import EditorUI
import Foundation
import IDEApplication
import IDEDomain
import SyntaxInfrastructure
import Testing

/// The whole chain on a real text view: session → coordinator → tree-sitter → presenter → pixels.
@MainActor
final class Screen {
    let editor: TextKitEditor
    let session: DocumentSession
    let coordinator: SyntaxCoordinator
    let presenter: SyntaxPresenter
    let scroll: NSScrollView
    let window: NSWindow

    init(_ text: String, policy: SyntaxPolicy = .standard) throws {
        editor = TextKitEditorFactory.makeEditor(loadedText: text)
        session = DocumentSession(path: "Main.swift", backend: editor.backend)
        coordinator = SyntaxCoordinator(session: session, source: editor.backend, highlighter: try TreeSitterHighlighter())
        presenter = SyntaxPresenter(textView: editor.textView, coordinator: coordinator, policy: policy)
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

    /// The characters TextKit is laying out for the view, from its viewport.
    func viewportCharacters() -> Range<Int>? {
        guard let manager = editor.textView.textLayoutManager, let content = manager.textContentManager,
              let viewport = manager.textViewportLayoutController.viewportRange else { return nil }

        let start = content.offset(from: content.documentRange.location, to: viewport.location)

        return start..<(start + content.offset(from: viewport.location, to: viewport.endLocation))
    }

    /// Lets the highlighter answer and the answers be applied, until the colours known are those of
    /// the current text over everything in the viewport, and then a little longer for the redraw
    /// that the last answer asked for.
    func settle(until condition: () -> Bool = { true }) async {
        for _ in 0..<600 {
            _ = render()
            try? await Task.sleep(for: .milliseconds(10))
            let window = coordinator.state.window
            let covered = viewportCharacters().map { window.lowerBound <= $0.lowerBound && $0.upperBound <= window.upperBound } ?? false
            if !coordinator.state.spans.isEmpty, covered, coordinator.lastResultVersion == session.version, condition() { break }
        }
        for _ in 0..<8 {
            _ = render()
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

/// Pixels that are clearly coloured, not grey text on white. Reads the bitmap's bytes: asking an
/// `NSColor` for every pixel took most of a second per picture and filled memory with colours.
func colourful(_ bitmap: NSBitmapImageRep) -> Int {
    guard let data = bitmap.bitmapData, bitmap.bitsPerSample == 8, bitmap.samplesPerPixel >= 3 else { return 0 }

    let step = bitmap.bitsPerPixel / 8
    var count = 0
    for y in 0..<bitmap.pixelsHigh {
        let row = data + y * bitmap.bytesPerRow
        for x in 0..<bitmap.pixelsWide {
            let pixel = row + x * step
            let r = Int(pixel[0]), g = Int(pixel[1]), b = Int(pixel[2])
            let high = max(r, g, b), low = min(r, g, b)
            // saturation > 0.45 and brightness < 0.9, in integers
            if high > 0, (high - low) * 100 > 45 * high, high * 10 < 9 * 255 { count += 1 }
        }
    }

    return count
}

func identical(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Bool {
    guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh,
          let da = a.representation(using: .png, properties: [:]), let db = b.representation(using: .png, properties: [:]) else { return false }

    return da == db
}

private let code = """
import Foundation

struct Greeter {
    let name: String
    // say hello
    func greet() -> String { "Hello, \\(name)! 42" }
}

"""

@Test @MainActor
func aDocumentIsColouredOnceTheHighlighterHasAnswered() async throws {
    let screen = try Screen(code)
    let before = colourful(screen.render())
    #expect(before == 0, "plain text is not coloured")
    await screen.settle()
    #expect(colourful(screen.render()) > 200, "keywords, strings, comments are drawn in colour")
}

@Test @MainActor
func colouringTouchesNeitherTheDocumentNorItsUndoHistory() async throws {
    let screen = try Screen(code)
    await screen.settle()
    #expect(screen.session.version == 0)
    #expect(!screen.session.isDirty)
    #expect(!screen.editor.undo.undoManager.canUndo)
    #expect(screen.editor.textView.string == code)
}

@Test @MainActor
func afterEditsTheScreenEqualsAFreshlyColouredCopy() async throws {
    let screen = try Screen(code)
    await screen.settle()

    // Edits that change colours far from where they are made: an opened string, a closed comment.
    screen.editor.textView.insertText("\"", replacementRange: NSRange(location: 20, length: 0))
    await screen.settle()
    screen.editor.textView.insertText("/*", replacementRange: NSRange(location: 0, length: 0))
    await screen.settle()
    screen.editor.textView.insertText("*/", replacementRange: NSRange(location: 40, length: 0))
    await screen.settle()

    let final = screen.editor.textView.string
    let fresh = try Screen(final)
    await fresh.settle()
    #expect(identical(screen.render(), fresh.render()), "the edited view looks like one coloured from scratch")
    #expect(screen.coordinator.resyncCount == 0, "followed every edit without starting over")
}

@Test @MainActor
func aLineLongerThanThePolicyIsLeftPlain() async throws {
    let long = "let x = " + String(repeating: "1 + ", count: 600) + "1\n"
    let screen = try Screen(long, policy: SyntaxPolicy(maximumFragmentLength: 2_000))
    await screen.settle()
    #expect(colourful(screen.render()) == 0)

    // The same line is coloured when the policy allows it: the plain result is the policy's doing.
    let allowed = try Screen(long, policy: SyntaxPolicy(maximumFragmentLength: 10_000, maximumSpansPerFragment: 10_000))
    await allowed.settle()
    #expect(colourful(allowed.render()) > 0)
}

@Test @MainActor
func aLineWithTooManyColouredRunsIsLeftPlain() async throws {
    // Short enough, but nearly every few characters is a coloured number.
    let dense = "let values = [" + (1...120).map(String.init).joined(separator: ", ") + "]\n"
    #expect(dense.utf16.count < 1_000)
    let screen = try Screen(dense)
    await screen.settle()
    #expect(colourful(screen.render()) == 0, "more runs than the policy allows")

    let allowed = try Screen(dense, policy: SyntaxPolicy(maximumFragmentLength: 1_000, maximumSpansPerFragment: 1_000))
    await allowed.settle()
    #expect(colourful(allowed.render()) > 0)
}

// MARK: Areas laid out before an edit

extension Screen {
    /// Scrolls to a fraction of the document, as dragging the scroller would, and lets it settle.
    func scroll(toFraction fraction: CGFloat) async {
        scroll.layoutSubtreeIfNeeded()
        let y = max(0, (editor.textView.frame.height - scroll.contentView.bounds.height) * fraction)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
        await settle()
    }
}

/// A long comment that opens on the first line and closes on the last: everything between is grey.
private let commentedLines = "/* start\n" + (1...400).map { "let value\($0) = \($0) + 1" }.joined(separator: "\n") + "\n*/\n"

@Test @MainActor
func textSeenBeforeAnEditIsRecolouredWhenScrolledBackToAfterIt() async throws {
    let screen = try Screen(commentedLines)
    await screen.settle()
    await screen.scroll(toFraction: 1)      // the bottom is laid out and coloured: all comment
    let before = colourful(screen.render())
    await screen.scroll(toFraction: 0)      // back at the top
    // Remove the opening: the lines below stop being a comment, the bottom included.
    screen.editor.textView.insertText("", replacementRange: NSRange(location: 0, length: 2))
    await screen.settle()
    await screen.scroll(toFraction: 1)      // the bottom was laid out before the edit
    let edited = screen.render()

    let fresh = try Screen(screen.editor.textView.string)
    await fresh.settle()
    await fresh.scroll(toFraction: 1)
    do {
        let dir = "/private/tmp/claude-501/-Users-resoul-projects-SwiftIDE/7a8f9a0f-b2dd-4965-bc7b-069a874909c0/scratchpad/"
        try edited.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: dir + "stale-edited.png"))
        try fresh.render().representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: dir + "stale-fresh.png"))
    } catch {}
    #expect(colourful(edited) > before + 100, "code colours appear where there was only comment grey")
    #expect(identical(edited, fresh.render()), "the bottom shows what a view coloured from scratch shows")
}

@Test @MainActor
func aDocumentCutDownWhileScrolledFarDownKeepsWorking() async throws {
    let screen = try Screen((1...400).map { "let value\($0) = \($0) // line \($0)" }.joined(separator: "\n") + "\n")
    await screen.settle()
    await screen.scroll(toFraction: 1)
    // Most of the text goes, including all that was on screen.
    screen.editor.textView.insertText("", replacementRange: NSRange(location: 200, length: screen.editor.textView.string.utf16.count - 400))
    await screen.settle()
    await screen.scroll(toFraction: 0)
    #expect(colourful(screen.render()) > 0, "what is left is coloured")
    #expect(screen.coordinator.resyncCount == 0)
}

@Test @MainActor
func typingAnOpeningCommentMarkGreysTheRestOfTheTextBeforeAnythingClosesIt() async throws {
    let lines = (1...14).map { "let value\($0) = \($0) + 1" }
    let screen = try Screen(lines.joined(separator: "\n") + "\n")
    await screen.settle()
    let before = colourful(screen.render())
    let opener = (lines[0..<6].joined(separator: "\n") + "\n").utf16.count

    // Typed the way a person types it: the slash, then the star.
    screen.editor.textView.insertText("/", replacementRange: NSRange(location: opener, length: 0))
    await screen.settle()
    screen.editor.textView.insertText("*", replacementRange: NSRange(location: opener + 1, length: 0))
    await screen.settle()
    let opened = screen.render()
    #expect(Double(colourful(opened)) < Double(before) * 0.6, "the lines below the opener are comment grey now")
    let fresh = try Screen(screen.editor.textView.string)
    await fresh.settle()
    #expect(identical(opened, fresh.render()))

    // Closing it two lines further down gives the code after that its colours back.
    let closeAt = (lines[0..<8].joined(separator: "\n")).utf16.count + 1
    screen.editor.textView.insertText("*/", replacementRange: NSRange(location: closeAt, length: 0))
    await screen.settle()
    let closedCopy = try Screen(screen.editor.textView.string)
    await closedCopy.settle()
    let closed = screen.render()
    #expect(identical(closed, closedCopy.render()))
    #expect(colourful(closed) > colourful(opened), "the lines after the closing mark are code again")
}
