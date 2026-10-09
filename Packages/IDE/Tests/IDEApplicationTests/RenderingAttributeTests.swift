import AppKit
import EditorPlatformTextKit
import EditorUI
import IDEApplication
import IDEDomain
import Testing

/// What syntax colouring may rely on (ADR-014, 007b): colours applied as TextKit 2 rendering
/// attributes are display-only, follow edits, are produced lazily per laid-out fragment, and
/// are refreshed by an attribute-only notification that names its range.
@MainActor
private struct Surface {
    let editor: TextKitEditor
    let session: DocumentSession
    let scroll: NSScrollView
    let window: NSWindow
    var layoutManager: NSTextLayoutManager { editor.textView.textLayoutManager! }

    init(_ text: String) {
        editor = TextKitEditorFactory.makeEditor(loadedText: text)
        session = DocumentSession(path: "Main.swift", backend: editor.backend)
        scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        scroll.documentView = editor.textView
        window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = scroll
    }

    func render() -> NSBitmapImageRep {
        scroll.layoutSubtreeIfNeeded()
        let bitmap = scroll.bitmapImageRepForCachingDisplay(in: scroll.bounds)!
        scroll.cacheDisplay(in: scroll.bounds, to: bitmap)
        return bitmap
    }

    func range(_ location: Int, _ length: Int) -> NSTextRange {
        let content = layoutManager.textContentManager!
        let start = content.location(content.documentRange.location, offsetBy: location)!
        return NSTextRange(location: start, end: content.location(start, offsetBy: length)!)!
    }

    /// Pixels of a strong colour: how much of a colour is on screen.
    func pixels(_ colour: Colour) -> Int { Self.count(colour, in: render()) }

    static func count(_ colour: Colour, in bitmap: NSBitmapImageRep) -> Int {
        var count = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                switch colour {
                case .red where c.redComponent > 0.7 && c.greenComponent < 0.3 && c.blueComponent < 0.3: count += 1
                case .blue where c.blueComponent > 0.7 && c.redComponent < 0.3 && c.greenComponent < 0.65: count += 1
                default: break
                }
            }
        }
        return count
    }

    enum Colour { case red, blue }

    /// Colours the first three characters of every fragment, the way a validator would.
    func installValidator(_ colour: @escaping @MainActor () -> NSColor, calls: Counter? = nil) {
        layoutManager.renderingAttributesValidator = { manager, fragment in
            MainActor.assumeIsolated {
                calls?.value += 1
                let content = manager.textContentManager!
                let start = fragment.rangeInElement.location
                if let end = content.location(start, offsetBy: 3), let range = NSTextRange(location: start, end: end) {
                    manager.setRenderingAttributes([.foregroundColor: colour()], for: range)
                }
            }
        }
    }

    /// The attribute-only notification that makes TextKit lay out and validate a range again.
    func refresh(_ range: NSRange) {
        let storage = editor.textView.textStorage!
        storage.beginEditing()
        storage.edited(.editedAttributes, range: range, changeInLength: 0)
        storage.endEditing()
    }
}

@MainActor
private final class Counter { var value = 0 }

@Test @MainActor
func renderingAttributesColourTextWithoutTouchingTheDocument() {
    let s = Surface("let x = 1\nlet y = 2\n")
    var published = 0
    s.session.subscribeToChanges { _ in published += 1 }
    let generation = s.editor.backend.editGeneration
    #expect(s.pixels(.red) == 0)

    s.layoutManager.setRenderingAttributes([.foregroundColor: NSColor.red], for: s.range(0, 3))
    #expect(s.pixels(.red) > 0, "the word is drawn red")
    #expect(s.session.version == 0 && published == 0, "no revision")
    #expect(s.editor.backend.editGeneration == generation, "storage untouched")
    #expect(!s.editor.undo.undoManager.canUndo, "nothing to undo")
    #expect(s.editor.textView.string == "let x = 1\nlet y = 2\n")
}

@Test @MainActor
func renderingAttributesFollowEditsAndTypedTextStartsPlain() {
    let s = Surface("let x = 1\n")
    s.layoutManager.setRenderingAttributes([.foregroundColor: NSColor.red], for: s.range(0, 3))

    func redRuns() -> [NSRange] {
        var runs: [NSRange] = []
        let content = s.layoutManager.textContentManager!
        s.layoutManager.enumerateRenderingAttributes(from: s.layoutManager.documentRange.location, reverse: false) { _, attributes, range in
            if attributes[.foregroundColor] as? NSColor == .red {
                let start = content.offset(from: content.documentRange.location, to: range.location)
                runs.append(NSRange(location: start, length: content.offset(from: range.location, to: range.endLocation)))
            }
            return true
        }
        return runs
    }

    s.editor.textView.insertText("ZZ", replacementRange: NSRange(location: 0, length: 0))   // before
    #expect(redRuns() == [NSRange(location: 2, length: 3)], "the colour moved with its text")

    s.editor.textView.insertText("Q", replacementRange: NSRange(location: 3, length: 0))     // inside
    #expect(redRuns() == [NSRange(location: 2, length: 1), NSRange(location: 4, length: 2)],
            "typed text inside a coloured word is plain and splits it")
}

@Test @MainActor
func theValidatorIsAskedOnlyForWhatIsLaidOut() {
    let s = Surface((1...20_000).map { "let value\($0) = \($0)" }.joined(separator: "\n"))
    let calls = Counter()
    s.installValidator({ .red }, calls: calls)
    _ = s.render()
    #expect(calls.value > 0 && calls.value < 400, "\(calls.value) fragments validated of 20 000 lines")
}

@Test @MainActor
func typingInAColouredFragmentKeepsItColoured() {
    let s = Surface("let x = 1\nlet y = 2\n")
    s.installValidator({ .red })
    let before = s.pixels(.red)
    #expect(before > 0)
    s.editor.textView.insertText("q", replacementRange: NSRange(location: 9, length: 0))
    #expect(s.pixels(.red) >= before, "the edited fragment was validated again")
}

@Test @MainActor
func anAttributeOnlyNotificationRevalidatesItsRangeWithoutARevision() {
    let s = Surface("let x = 1\nlet y = 2\n")
    var colour = NSColor.red
    s.installValidator({ colour })
    #expect(s.pixels(.red) > 0 && s.pixels(.blue) == 0)

    var published = 0
    s.session.subscribeToChanges { _ in published += 1 }
    let generation = s.editor.backend.editGeneration
    colour = .systemBlue
    s.refresh(NSRange(location: 0, length: s.editor.textView.string.utf16.count))
    #expect(s.pixels(.blue) > 0 && s.pixels(.red) == 0, "the new colour replaced the old one")
    #expect(published == 0 && s.session.version == 0, "attribute-only: no revision")
    #expect(s.editor.backend.editGeneration == generation)
    #expect(!s.editor.undo.undoManager.canUndo)
}

@Test @MainActor
func aRefreshOfOneLineLeavesTheOthersAsTheyWere() {
    let s = Surface("let x = 1\nlet y = 2\n")
    var colour = NSColor.red
    s.installValidator({ colour })
    let both = s.pixels(.red)
    colour = .systemBlue
    s.refresh(NSRange(location: 0, length: 9))   // the first line only
    let red = s.pixels(.red), blue = s.pixels(.blue)
    #expect(blue > 0 && red > 0, "one line changed, one did not")
    #expect(red < both)
}

@Test @MainActor
func aValidatorMustClearItsFragmentBecauseOldColoursStayOtherwise() {
    // TextKit does not drop a fragment's old rendering attributes when it validates it again: a
    // validator that stops colouring a stretch has to remove the colour itself.
    for clears in [false, true] {
        let s = Surface("let x = 1\nlet y = 2\n")
        var colours = true
        s.layoutManager.renderingAttributesValidator = { manager, fragment in
            MainActor.assumeIsolated {
                if clears { manager.removeRenderingAttribute(.foregroundColor, for: fragment.rangeInElement) }
                guard colours else { return }
                let content = manager.textContentManager!
                let start = fragment.rangeInElement.location
                if let end = content.location(start, offsetBy: 3), let range = NSTextRange(location: start, end: end) {
                    manager.setRenderingAttributes([.foregroundColor: NSColor.red], for: range)
                }
            }
        }
        #expect(s.pixels(.red) > 0)
        colours = false
        s.refresh(NSRange(location: 0, length: s.editor.textView.string.utf16.count))
        if clears {
            #expect(s.pixels(.red) == 0, "removed before colouring: nothing is left")
        } else {
            #expect(s.pixels(.red) > 0, "not removed: the old colour stays")
        }
    }
}
