import IDEDomain

/// Computes colours for a document on its own thread, from the text and the edits it is told about.
///
/// Every method returns at once; work happens elsewhere and the answer comes back through the
/// handler given to `connect`. Messages are processed in the order they were sent, so a request
/// made after an edit sees that edit. A result names the version it is for, and is only worth
/// using while the document is still at that version.
public protocol SyntaxHighlighter: AnyObject, Sendable {
    func connect(onResult: @escaping @Sendable (HighlightResult) -> Void)
    /// Starts over from this text: the first message, and the answer to any loss of sync.
    func reset(text: [[UInt16]], version: UInt64)
    /// Follows an edit; the highlighter keeps its own copy of the text.
    func edit(_ changes: DocumentChangeSet)
    /// Asks for the colours of `window` at `version`. Parsing happens here, not on the edit.
    func requestHighlights(in window: Range<Int>, version: UInt64)
    func stop()
}
