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

    public init() {}
}
