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

    /// The file as it is now, judged by its bytes, or nil if there is no such file. Throws for what
    /// is not a regular file. `known` is a revision the caller already has: if the file's identity,
    /// size and modification time are still those, it comes back without the file being read, so
    /// that a directory event is not a reason to read a 100 MB file.
    func currentRevision(path: String, assumingUnchangedFrom known: FileRevision?) async throws -> FileRevision?
}

extension DocumentFileStore {
    /// For stores that have no cheaper way: reads the file. A store that can look at a file's
    /// metadata, or hash it without decoding, should provide its own.
    public func currentRevision(path: String, assumingUnchangedFrom known: FileRevision?) async throws -> FileRevision? {
        do {
            return try await read(path: path, maximumBytes: .max).revision
        } catch FileStoreError.notFound {
            return nil
        }
    }
}
