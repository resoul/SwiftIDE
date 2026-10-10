import Foundation
import IDEDomain

/// What became of the file a recovered text belongs to.
public enum RecoveredDiskState: Equatable, Sendable {
    /// The document never had a file.
    case notApplicable
    /// The file is exactly as it was when the text was kept.
    case unchanged
    /// The file was changed by someone else since.
    case changed
    case missing
    /// The file exists but cannot be opened as text any more.
    case unreadable
}

public struct RecoveryCandidate: Equatable, Sendable {
    public let record: RecoveryRecord
    public let disk: RecoveredDiskState

    public init(record: RecoveryRecord, disk: RecoveredDiskState) {
        self.record = record
        self.disk = disk
    }
}

public struct RecoveryScan: Equatable, Sendable {
    public var candidates: [RecoveryCandidate]
    /// Entries of the store that could not be read, described for the user.
    public var unreadable: [String]
}

public enum RestoreOutcome: Equatable, Sendable {
    /// Opened at its file, with the recovered text as unsaved changes.
    case restored
    /// Opened as an untitled document: there is no file to open it at.
    case restoredAsScratch
    /// The recovered text is the file's text: there was nothing to restore.
    case nothingToRestore
    /// A window already holds unsaved changes to this file; they are newer, so they are kept.
    case alreadyOpenAndModified
}

public struct RestoredDocument: Sendable {
    public let session: DocumentSession?
    public let outcome: RestoreOutcome
    /// True if the document needs a window of its own.
    public let isNew: Bool
}

/// Finds the unsaved text a previous run left behind and turns it back into documents (ADR-016).
///
/// Restoring changes nothing on disk. The text becomes an ordinary unsaved edit of the file, so it
/// can be undone, and it is based on the file as it was when the text was kept: if the file
/// changed since, saving is a conflict and the user chooses, exactly as for any other change made
/// behind the editor's back.
@MainActor
public final class RecoveryRestorer {
    private let store: any RecoveryStore
    private let files: any DocumentFileStore
    private let open: OpenDocumentUseCase
    private let makeScratch: @MainActor (String) -> DocumentSession
    private let maximumBytes: Int

    /// `makeScratch` is the platform's part: an untitled document (with its editor) of no text,
    /// for the given title.
    public init(
        store: any RecoveryStore,
        files: any DocumentFileStore,
        open: OpenDocumentUseCase,
        maximumBytes: Int = OpenDocumentUseCase.defaultMaximumBytes,
        makeScratch: @escaping @MainActor (String) -> DocumentSession
    ) {
        self.store = store
        self.files = files
        self.open = open
        self.maximumBytes = maximumBytes
        self.makeScratch = makeScratch
    }

    public func scan() async throws -> RecoveryScan {
        let listing = try await store.pending()
        var candidates: [RecoveryCandidate] = []
        for record in listing.records {
            candidates.append(RecoveryCandidate(record: record, disk: await diskState(of: record)))
        }

        return RecoveryScan(candidates: candidates, unreadable: listing.unreadable)
    }

    private func diskState(of record: RecoveryRecord) async -> RecoveredDiskState {
        guard let path = record.path else { return .notApplicable }

        do {
            let file = try await files.read(path: path, maximumBytes: maximumBytes)
            if let base = record.baseRevision, file.revision.hasSameContent(as: base) { return .unchanged }

            return .changed
        } catch FileStoreError.notFound {
            return .missing
        } catch {
            return .unreadable
        }
    }

    public func restore(_ candidate: RecoveryCandidate) async throws -> RestoredDocument {
        let record = candidate.record
        switch candidate.disk {
        case .unchanged, .changed:
            guard let path = record.path else { return try restoreAsScratch(record) }

            let opened = try await open.execute(path: path)
            let session = opened.session
            // Whatever was typed into an already open window since the app started is newer.
            if !opened.isNew, session.isDirty {
                return RestoredDocument(session: nil, outcome: .alreadyOpenAndModified, isNew: false)
            }

            try session.replaceText(record.text, expectedVersion: session.version)
            guard session.isDirty else {
                return RestoredDocument(session: nil, outcome: .nothingToRestore, isNew: false)
            }

            // A save is judged against what the text was based on, not against what is there now,
            // and not against what the scan found: the file may have changed since the scan, while
            // the question was on screen. If it did not, the store sees the same bytes and no
            // conflict.
            session.rebaseOnto(record.baseRevision)

            return RestoredDocument(session: session, outcome: .restored, isNew: opened.isNew)
        case .notApplicable, .missing, .unreadable:
            return try restoreAsScratch(record)
        }
    }

    private func restoreAsScratch(_ record: RecoveryRecord) throws -> RestoredDocument {
        let session = makeScratch(record.title)
        try session.replaceText(record.text, expectedVersion: session.version)
        guard session.isDirty else {
            return RestoredDocument(session: nil, outcome: .nothingToRestore, isNew: false)
        }

        return RestoredDocument(session: session, outcome: .restoredAsScratch, isNew: true)
    }

    /// The restored document has its own record now: the one it came from may go, but only once
    /// the new one is confirmed written (`afterKeeping` makes it so and returns the receipt). The
    /// receipt must cover the text that was restored: a record of at least the version the
    /// document had when this was called. If it could not be written (the disk refused, the text
    /// is too large to keep) the old record is the only copy there is and stays. Returns whether
    /// the old record was removed.
    @discardableResult
    public func retire(
        _ candidate: RecoveryCandidate,
        restoredAs session: DocumentSession,
        afterKeeping keep: @MainActor () async -> Safekeeping?
    ) async throws -> Bool {
        let needed = session.version
        let safe: Bool
        switch await keep() {
        case nil: safe = false
        case .nothingUnsaved?: safe = true   // saved meanwhile: the file holds the text
        case .written(_, let version)?: safe = version >= needed
        }
        // Asked after the wait: the document may have been saved under another name meanwhile.
        guard safe, candidate.record.key != session.recoveryKey else { return false }

        try await store.remove(candidate.record.key)

        return true
    }

    /// Removes the record of a candidate the user declined or that was restored. `unlessKept` is
    /// the key the restored document writes under: that record is overwritten by the new
    /// document's own, and removing it first would leave a moment in which a crash loses the text.
    public func discard(_ candidate: RecoveryCandidate, unlessKept: RecoveryKey? = nil) async throws {
        guard candidate.record.key != unlessKept else { return }

        try await store.remove(candidate.record.key)
    }
}
