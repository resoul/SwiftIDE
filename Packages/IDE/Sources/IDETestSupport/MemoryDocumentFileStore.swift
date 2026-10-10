import IDEApplication
import IDEDomain

/// Demo/test adapter: process-local, with the same revision rules as the real store but no
/// filesystem. It is not evidence of atomic saving.
public actor MemoryDocumentFileStore: DocumentFileStore {
    private struct Entry {
        var text: String
        var revision: FileRevision
    }

    private var entries: [String: Entry] = [:]
    private var clock: Int64 = 0

    public init(contents: [String: String] = [:]) {
        var tick: Int64 = 0
        for (path, text) in contents {
            tick += 1
            entries[path] = Entry(text: text, revision: Self.revision(path, text, tick))
        }
        clock = tick
    }

    public func read(path: String, maximumBytes: Int) async throws -> LoadedFile {
        guard let entry = entries[path] else { throw FileStoreError.notFound }
        let size = UInt64(entry.text.utf8.count)
        guard size <= maximumBytes else { throw FileStoreError.tooLarge(size: size, limit: maximumBytes) }
        return LoadedFile(path: path, text: entry.text, encoding: .utf8, revision: entry.revision)
    }

    public func write(_ snapshot: DocumentSnapshot, expecting: SaveExpectation) async throws -> FileRevision {
        try Task.checkCancellation()
        if case .revision(let expected) = expecting {
            let current = entries[snapshot.path]?.revision
            switch (expected, current) {
            case (nil, nil): break
            case (let expected?, let current?) where expected == current: break
            default: throw FileStoreError.conflict(current: current)
            }
        }
        let revision = nextRevision(snapshot.path, snapshot.text)
        entries[snapshot.path] = Entry(text: snapshot.text, revision: revision)
        return revision
    }

    public func currentRevision(path: String, assumingUnchangedFrom known: FileRevision?) async throws -> FileRevision? {
        entries[path]?.revision
    }

    public func text(at path: String) -> String? {
        entries[path]?.text
    }

    /// Simulates another program writing the file.
    public func externallyWrite(_ text: String, at path: String) {
        entries[path] = Entry(text: text, revision: nextRevision(path, text))
    }

    /// Simulates the file being deleted by another program.
    public func remove(_ path: String) {
        entries.removeValue(forKey: path)
    }

    public func revision(at path: String) -> FileRevision? {
        entries[path]?.revision
    }

    private func nextRevision(_ path: String, _ text: String) -> FileRevision {
        clock += 1
        return Self.revision(path, text, clock)
    }

    private static func revision(_ path: String, _ text: String, _ clock: Int64) -> FileRevision {
        FileRevision(
            fileID: FileIdentity(device: 0, inode: UInt64(truncatingIfNeeded: path.hashValue)),
            size: UInt64(text.utf8.count), modificationTime: clock,
            contentDigest: ContentDigest(bytes: Array(text.utf8.prefix(32)))
        )
    }
}
