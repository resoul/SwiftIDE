import IDEDomain

/// A text change the editor view has already applied to its storage.
public struct NativeEditCommit: Sendable {
    public let transactionID: TransactionID
    public let origin: EditOrigin
    /// Exact replacements in coordinates of the last consistent text, when the editor knew them
    /// before mutating. `nil` means "derive the change from before/after text".
    public let exactEdits: [DocumentEdit]?

    public init(
        transactionID: TransactionID = TransactionID(), origin: EditOrigin, exactEdits: [DocumentEdit]?
    ) {
        self.transactionID = transactionID
        self.origin = origin
        self.exactEdits = exactEdits
    }
}

/// Implemented by the session; called by a backend whose view can mutate storage on its own.
@MainActor
public protocol NativeEditReceiver: AnyObject {
    /// Cheap preflight. `false` means the edit must be refused before it mutates storage.
    func allowsNativeEdit() -> Bool
    /// Storage already changed. The receiver reconciles its version with the backend text and
    /// never writes back into storage. Attribute-only and no-op callbacks are ignored.
    func nativeEditDidCommit(_ commit: NativeEditCommit)
    func compositionDidChange(_ event: CompositionEvent)
}
