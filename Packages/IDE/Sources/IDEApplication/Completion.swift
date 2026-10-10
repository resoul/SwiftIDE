import Foundation
import IDEDomain

// What a completion is, as the editor sees it. A language server fills these in; nothing here
// knows which one.

public enum CompletionKind: Equatable, Sendable {
    case method, function, initializer, property, variable, type, keyword, constant, module, other
}

public struct CompletionItem: Equatable, Sendable {
    public let label: String
    public let detail: String?
    public let insertText: String?
    public let sortText: String?
    public let filterText: String?
    /// The text the item replaces, in the document the request was made against.
    public let replacementRange: UTF16TextRange?
    public let kind: CompletionKind

    public init(
        label: String, detail: String? = nil, insertText: String? = nil, sortText: String? = nil,
        filterText: String? = nil, replacementRange: UTF16TextRange? = nil, kind: CompletionKind = .other
    ) {
        self.label = label
        self.detail = detail
        self.insertText = insertText
        self.sortText = sortText
        self.filterText = filterText
        self.replacementRange = replacementRange
        self.kind = kind
    }
}

public enum StaleReason: Equatable, Sendable {
    case documentChanged
    case caretMoved
    case serverRestarted
    case compositionStarted
    case cancelled
}

public enum LanguageServiceUnavailable: Equatable, Sendable {
    /// There is no server for this document (another kind of file, too large, or none started).
    case notRunning
    /// The server is being started.
    case starting
    /// The server went away and a new one is being started.
    case restarting
    /// The server has not been given the document's current text yet (it is being opened or resynchronised).
    case documentNotSynced
    case failed(String)
}

public enum CompletionOutcome: Equatable, Sendable {
    case items([CompletionItem], isIncomplete: Bool)
    /// The answer was for text, a caret or a server that is not current any more, and is dropped.
    case stale(StaleReason)
    /// The input method holds marked text: completion does not touch it.
    case suppressedByComposition
    case unavailable(LanguageServiceUnavailable)
}

/// Where completions come from. `caret` is asked again when the answer arrives, so that an answer
/// for a caret that has moved on is dropped by the provider.
@MainActor
public protocol CompletionProviding: AnyObject {
    func completion(for session: DocumentSession, caret: @MainActor () -> Int) async -> CompletionOutcome
}

/// Why there is no list, when the user asked for one and is looking at the screen. What the
/// completion tells the user instead of staying silent.
public enum CompletionStatus: Equatable, Sendable {
    /// The question is out and the answer has taken a while.
    case waiting
    case starting
    case restarting
    /// The server has not been given the document yet.
    case notReady
    case noSuggestions
    /// The server cannot be used: it failed, or there is none for this document.
    case unavailable
    /// The question went unanswered for the time allowed and was withdrawn.
    case notResponding
}
