import IDEDomain

/// Owned exclusively by one DocumentSession; AppKit stays behind this port.
///
/// Reading is split by cost. Everything on the editing path (`TextSource`, `editGeneration`) is
/// O(1) or proportional to the edit; only `text` copies the document, and it is for the moments
/// that need a snapshot: saving, opening in a language server, reloading.
@MainActor
public protocol DocumentEditingBackend: AnyObject, TextSource {
    /// A copy of the whole text, independent of later storage mutations. O(n): never call it per
    /// keystroke.
    var text: String { get }

    /// Counts every pass that changed characters in the backend's storage, whoever made it. A
    /// session that finds a different value than the one it last accounted for knows someone
    /// edited behind its back.
    var editGeneration: UInt64 { get }

    /// Synchronous commit of a prevalidated plan, with no callbacks into the session.
    /// The caller must have prepared it against the current text and cannot mutate elsewhere.
    func commit(_ plan: PreparedDocumentEdit)

    /// The owning session registers itself once. A backend whose view mutates storage on its
    /// own reports those mutations here; the reference must be held weakly.
    func attach(nativeEditReceiver: any NativeEditReceiver)

    /// Asks the input method to finish any marked text in the standard way. Completion is
    /// signalled through `NativeEditReceiver.compositionDidChange(.ended)`, possibly later.
    func endComposition()
}

extension DocumentEditingBackend {
    public func attach(nativeEditReceiver: any NativeEditReceiver) {}
    public func endComposition() {}
}
