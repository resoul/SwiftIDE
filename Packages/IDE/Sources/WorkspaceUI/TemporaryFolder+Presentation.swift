import IDEApplication

public extension TemporaryFolder {
    /// The words for the window subtitle, or nil when there is nothing to say.
    static func note(path: String, isCFamily: Bool) -> String? {
        guard isCFamily, contains(path) else { return nil }

        return "temporary folder: C-family flags may be missing"
    }
}
