import IDEDomain

/// Owned exclusively by one DocumentSession; AppKit stays behind this port.
@MainActor
public protocol DocumentEditingBackend: AnyObject {
    /// Must return an immutable value independent of later storage mutations.
    var text: String { get }

    /// Synchronous commit of a prevalidated plan, with no callbacks into the session.
    /// The caller must use the same source text and cannot mutate storage elsewhere.
    func commit(_ plan: PreparedDocumentEdit)
}
