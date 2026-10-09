import IDEApplication
import IDEDomain

/// Headless/reference adapter used by tests. Production uses TextKitDocumentBackend.
/// It can also play the role of a view that mutates its storage on its own.
@MainActor
public final class StringDocumentBackend: DocumentEditingBackend {
    public private(set) var text: String
    public private(set) var endCompositionRequests = 0
    private weak var receiver: (any NativeEditReceiver)?

    public init(loadedText: String) {
        self.text = loadedText
    }

    public func commit(_ plan: PreparedDocumentEdit) {
        precondition(text.utf8.elementsEqual(plan.sourceText.utf8))
        text = plan.resultText
    }

    public func attach(nativeEditReceiver: any NativeEditReceiver) {
        receiver = nativeEditReceiver
    }

    public func endComposition() {
        endCompositionRequests += 1
    }

    // MARK: Simulated native view

    /// Replaces text behind the session's back and reports it like a native edit.
    /// `exact` is what the view claims to know before mutating; `nil` forces reconciliation.
    @discardableResult
    public func simulateNativeEdit(
        _ range: UTF16TextRange, with replacement: String, origin: EditOrigin = .typing,
        exact: [DocumentEdit]? = nil, report: Bool = true
    ) -> NativeEditCommit {
        let units = Array(text.utf16)
        let updated = Array(units[..<range.location]) + Array(replacement.utf16)
            + Array(units[(range.location + range.length)...])
        text = String(decoding: updated, as: UTF16.self)
        let commit = NativeEditCommit(origin: origin, exactEdits: exact)
        if report { receiver?.nativeEditDidCommit(commit) }
        return commit
    }

    public func reportAgain(_ commit: NativeEditCommit) {
        receiver?.nativeEditDidCommit(commit)
    }

    public func simulateComposition(_ event: CompositionEvent) {
        receiver?.compositionDidChange(event)
    }

    public var allowsNativeEdit: Bool { receiver?.allowsNativeEdit() ?? true }
}
