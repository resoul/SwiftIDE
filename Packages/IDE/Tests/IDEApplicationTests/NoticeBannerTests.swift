import AppKit
import EditorPlatformTextKit
import EditorUI
import IDEApplication
import Testing

@MainActor
private struct Layout {
    let container: EditorContainerView
    let window: NSWindow

    init() {
        let editor = TextKitEditorFactory.makeEditor(loadedText: "let a = 1\nlet b = 2\n")
        container = EditorContainerView(host: EditorHostView(editor: editor))
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = container
        settle()
    }

    func settle() { container.layoutSubtreeIfNeeded() }
}

@Test @MainActor
func aHiddenBannerTakesNoSpaceAndAShownOneTakesItFromTheEditor() {
    let l = Layout()
    let full = l.container.host.frame.height
    #expect(l.container.banner.isHidden)

    l.container.banner.show(message: "A very long line.", buttons: [.init(title: "OK", action: {})])
    l.settle()
    #expect(l.container.banner.frame.height > 10)
    #expect(l.container.host.frame.height < full)
    #expect(abs(l.container.banner.frame.height + l.container.host.frame.height - full) < 1, "nothing else moved")

    l.container.banner.hide()
    l.settle()
    #expect(abs(l.container.host.frame.height - full) < 1)
}

@Test @MainActor
func theBannersButtonsRunTheirActionsInOrder() {
    let l = Layout()
    var pressed: [String] = []
    l.container.banner.show(message: "Message", buttons: [
        .init(title: "First", action: { pressed.append("first") }),
        .init(title: "Second", action: { pressed.append("second") })
    ])
    l.settle()
    let buttons = allButtons(in: l.container.banner)
    #expect(buttons.map(\.title) == ["First", "Second"])
    buttons[1].performClick(nil)
    buttons[0].performClick(nil)
    #expect(pressed == ["second", "first"])
}

@MainActor
private func allButtons(in view: NSView) -> [NSButton] {
    var found: [NSButton] = []
    if let button = view as? NSButton { found.append(button) }
    for sub in view.subviews { found += allButtons(in: sub) }
    return found
}
