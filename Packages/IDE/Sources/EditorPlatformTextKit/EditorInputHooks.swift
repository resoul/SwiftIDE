import AppKit

/// Where the editor's text view lets the rest of the application in on input, without the
/// application subclassing the view.
@MainActor
public final class EditorInputHooks {
    /// A key press, before the text view acts on it; true if it was used. Not asked while an input
    /// method holds marked text: the keys then belong to it.
    public var interceptKey: ((NSEvent) -> Bool)?
    /// The user asked for completion: Control-Space, Escape or F5 (the system "complete" command).
    public var requestCompletion: (() -> Void)?

    /// The pointer moved over the character at this offset, or over no character of the text (nil).
    public var pointerMoved: ((Int?) -> Void)?
    /// A click with Command held on the character at this offset; true if it was used.
    public var commandClick: ((Int) -> Bool)?
    /// The user asked for the description of the symbol at the caret: Control-Shift-Space.
    public var requestHover: (() -> Void)?
    /// A key was pressed, the mouse was clicked or the text was scrolled: what is on screen about a
    /// place (a description) is out of date.
    public var interactionBegan: (() -> Void)?

    public init() {}
}
