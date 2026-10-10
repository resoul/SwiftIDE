import IDEDomain

/// What a native input operation did to the text, described without comparing whole texts.
public enum NativeTextEffect: Sendable, Equatable {
    /// Only attributes changed, or characters were replaced by themselves.
    case unchanged
    /// `range` (in coordinates of the text before) was replaced by `replacement`. `isExact` is
    /// true when the editor knew that edit before it happened; otherwise the replacement is the
    /// smallest region the editor reports as changed, which covers the change but may include
    /// characters that did not change.
    case replaced(range: UTF16TextRange, replacement: String, isExact: Bool)
    /// The editor cannot say what changed.
    case unknown
}

/// A text change the editor view has already applied to its storage.
public struct NativeEditCommit: Sendable {
    public let transactionID: TransactionID
    public let origin: EditOrigin
    public let effect: NativeTextEffect
    /// Storage passes this commit covers, and the backend's `editGeneration` after the last of
    /// them. The session checks that `generation - passes` is what it had accounted for.
    public let passes: Int
    public let generation: UInt64

    public init(
        transactionID: TransactionID = TransactionID(),
        origin: EditOrigin,
        effect: NativeTextEffect,
        passes: Int = 1,
        generation: UInt64
    ) {
        self.transactionID = transactionID
        self.origin = origin
        self.effect = effect
        self.passes = passes
        self.generation = generation
    }
}

/// Implemented by the session; called by a backend whose view can mutate storage on its own.
@MainActor
public protocol NativeEditReceiver: AnyObject {
    /// Cheap preflight. `false` means the edit must be refused before it mutates storage.
    func allowsNativeEdit() -> Bool
    /// Storage already changed. The receiver brings its version up to date from the commit,
    /// without reading the text and without writing into storage.
    func nativeEditDidCommit(_ commit: NativeEditCommit)
    func compositionDidChange(_ event: CompositionEvent)
}
