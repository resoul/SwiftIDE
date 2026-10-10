import Foundation
import IDEDomain

// What a language server can tell the editor besides completions: the description of a symbol and
// where it is defined. Like completion (Completion.swift) these know nothing of any protocol.

/// Why an answer was not obtained or not used.
public enum LanguageRequestFailure: Error, Equatable, Sendable {
    /// For text, a caret or a server that is not current any more (or the request was withdrawn).
    case stale(StaleReason)
    /// The input method holds marked text: nothing is asked meanwhile.
    case suppressedByComposition
    case unavailable(LanguageServiceUnavailable)
}

public extension CompletionOutcome {
    init(_ failure: LanguageRequestFailure) {
        switch failure {
        case .stale(let reason): self = .stale(reason)
        case .suppressedByComposition: self = .suppressedByComposition
        case .unavailable(let reason): self = .unavailable(reason)
        }
    }
}

// MARK: Hover

public struct HoverContent: Equatable, Sendable {
    /// Plain text: Markdown fences and emphasis are taken off, the words stay.
    public let text: String
    /// The text the description is about, in the document the request was made against.
    public let range: UTF16TextRange?

    public init(text: String, range: UTF16TextRange? = nil) {
        self.text = text
        self.range = range
    }
}

public enum HoverOutcome: Equatable, Sendable {
    case content(HoverContent)
    /// The server has nothing to say about that place.
    case nothing
    case failed(LanguageRequestFailure)
}

/// Where hover descriptions come from. `offset` is asked again when the answer arrives.
@MainActor
public protocol HoverProviding: AnyObject {
    func hover(for session: DocumentSession, offset: @MainActor () -> Int) async -> HoverOutcome
}

// MARK: Definition

public struct DefinitionLocation: Equatable, Sendable {
    public let path: String
    /// Zero-based line, and the UTF-16 offset within it, as the protocol counts them.
    public let line: Int
    public let character: Int
    /// The UTF-16 offset in the text, when the place is in the document asked about.
    public let offset: Int?

    public init(path: String, line: Int, character: Int, offset: Int? = nil) {
        self.path = path
        self.line = line
        self.character = character
        self.offset = offset
    }
}

public enum DefinitionOutcome: Equatable, Sendable {
    case locations([DefinitionLocation])
    case nothing
    case failed(LanguageRequestFailure)
}

@MainActor
public protocol DefinitionProviding: AnyObject {
    func definition(for session: DocumentSession, offset: @MainActor () -> Int) async -> DefinitionOutcome
}
