import IDEDomain

extension DocumentLanguage {
    /// The `languageId` a language server is told for a document. Plain text has none. How a
    /// language is named on the wire is this module's matter, not the domain's.
    public var languageServerID: String? {
        switch self {
        case .swift: "swift"
        case .c: "c"
        case .cpp: "cpp"
        case .objectiveC: "objective-c"
        case .objectiveCPP: "objective-cpp"
        case .plainText: nil
        }
    }
}
