import IDEApplication

/// Headless/reference adapter used by tests. Production chooses TextKitDocumentBackend.
@MainActor
public final class StringDocumentBackend: DocumentEditingBackend {
    public private(set) var text: String

    public init(loadedText: String) {
        self.text = loadedText
    }

    public func commit(_ plan: PreparedDocumentEdit) {
        precondition(text.utf8.elementsEqual(plan.sourceText.utf8))
        text = plan.resultText
    }
}
