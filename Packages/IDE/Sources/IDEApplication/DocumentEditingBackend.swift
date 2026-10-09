import IDEDomain

/// Owned exclusively by one DocumentSession; AppKit stays behind this port.
@MainActor
public protocol DocumentEditingBackend: AnyObject {
    /// Must return an immutable value independent of later storage mutations.
    var text: String { get }

    /// Synchronous commit of a prevalidated plan, with no callbacks into the session.
    /// The caller must use the same source text and cannot mutate storage elsewhere.
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
