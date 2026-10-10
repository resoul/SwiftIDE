import Foundation

/// The language of a document, as one value for everyone who needs it: colours, language servers
/// and editor commands. It names the language; grammars and protocol types live elsewhere.
public enum DocumentLanguage: String, CaseIterable, Codable, Sendable {
    case swift
    case c
    case cpp
    case objectiveC
    case objectiveCPP
    case plainText

    public var displayName: String {
        switch self {
        case .swift: "Swift"
        case .c: "C"
        case .cpp: "C++"
        case .objectiveC: "Objective-C"
        case .objectiveCPP: "Objective-C++"
        case .plainText: "Plain Text"
        }
    }

    /// What the file name says. `isProvisional` is for names that fit more than one language: a
    /// `.h` is taken for C until something better is known.
    public struct Guess: Equatable, Sendable {
        public let language: DocumentLanguage
        public let isProvisional: Bool

        public init(language: DocumentLanguage, isProvisional: Bool) {
            self.language = language
            self.isProvisional = isProvisional
        }
    }

    public static func guess(forPath path: String) -> Guess {
        let name = (path as NSString).lastPathComponent
        let raw = (name as NSString).pathExtension
        // `.C` is C++ by convention; the other names do not depend on case.
        let ext = raw == "C" ? raw : raw.lowercased()
        switch ext {
        case "swift", "swiftinterface": return Guess(language: .swift, isProvisional: false)
        case "c": return Guess(language: .c, isProvisional: false)
        case "cpp", "cc", "cxx", "hpp", "hh", "hxx", "C": return Guess(language: .cpp, isProvisional: false)
        case "m": return Guess(language: .objectiveC, isProvisional: false)
        case "mm": return Guess(language: .objectiveCPP, isProvisional: false)
        case "h": return Guess(language: .c, isProvisional: true)
        default: return Guess(language: .plainText, isProvisional: false)
        }
    }
}
