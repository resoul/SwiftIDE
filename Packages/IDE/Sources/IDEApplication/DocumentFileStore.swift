import IDEDomain

/// Consumer-owned port to persistent text files.
public protocol DocumentFileStore: Sendable {
    /// Reads text, refusing files larger than `maximumBytes`, non-text and unsupported encodings.
    /// Never replaces invalid bytes silently.
    func read(path: String, maximumBytes: Int) async throws -> LoadedFile

    /// Replaces the file with the snapshot and returns the revision of what was written.
    /// With `.revision` the file must still match it, else `FileStoreError.conflict`; an
    /// overwrite is only done for `.overwrite`.
    func write(_ snapshot: DocumentSnapshot, expecting: SaveExpectation) async throws -> FileRevision
}
