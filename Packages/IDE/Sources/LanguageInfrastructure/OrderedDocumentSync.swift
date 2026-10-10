import Foundation
import IDEApplication
import IDEDomain

public enum DocumentSyncError: Error, Equatable {
    /// Over the size the language server is given.
    case tooLarge(utf16Length: Int, limit: Int)
    /// A document with no file has no address the server could use.
    case untitled
    case unsupportedLanguage
    case alreadyOpen
}

/// Keeps a language server's idea of each open document equal to the document, in order.
///
/// A document's changes are turned into `didChange` messages inside the session's own change
/// callback, which runs on the main actor in the order the edits happened, and put in the
/// connection's outbox right there. Nothing is deferred to a task, so nothing can overtake
/// anything: a completion request made after an edit reaches the server after it. What cannot be
/// kept in order is not kept at all: if the outbox grows past its limit, or a change cannot be
/// followed, the document is marked for resynchronisation and one full-text `didChange`, built
/// from the text of the moment it is written, replaces the changes that were not sent.
@MainActor
public final class OrderedDocumentSync {
    public struct Limits: Sendable {
        /// Documents longer than this (UTF-16 units) are not given to the server.
        public var maximumUTF16Length: Int
        /// When this many messages wait to be written, further changes are folded into a resync.
        public var maximumPendingMessages: Int

        public init(maximumUTF16Length: Int = 8 * 1_048_576, maximumPendingMessages: Int = 500) {
            self.maximumUTF16Length = maximumUTF16Length
            self.maximumPendingMessages = maximumPendingMessages
        }
    }

    private enum Phase {
        /// The text is being copied; changes made meanwhile are kept to be sent after it.
        case opening(buffered: [DocumentChangeSet])
        case synced
        /// A full-text `didChange` is in the outbox; until it is written the index is not followed.
        case resyncing
    }

    private final class Tracked {
        let session: DocumentSession
        var uri: String
        var index: LineIndex
        var phase: Phase = .opening(buffered: [])
        /// The session version the server will have once everything in the outbox is read.
        var enqueuedVersion: UInt64 = 0
        var changeSubscription: UUID?
        var saveSubscription: UUID?
        /// Counts every time the document was given to the server anew, so a late result of an
        /// earlier attempt can tell.
        var epoch = 0
        /// The server has the document at `uri`: `didOpen` was sent and `didClose` was not.
        var isOpenOnServer = false

        init(session: DocumentSession) {
            self.session = session
            uri = ""
            index = LineIndex()
        }
    }

    public let limits: Limits
    private let capturePolicy: CapturePolicy
    private var tracked: [DocumentID: Tracked] = [:]
    private var connection: LanguageServerConnection?
    /// Changes every time the server is replaced: answers of an earlier one are for another session.
    public private(set) var generation = 0
    /// How many times a document was resynchronised by full text, for tests and for diagnosis.
    public private(set) var resyncCount = 0

    /// Copies a document's text with its version; `DocumentSession.capture` unless a test steps in.
    typealias Capture = @MainActor (DocumentSession, CapturePolicy) async throws -> DocumentCapture
    private let capture: Capture

    /// Where documents that have no file yet are said to live. A server wants a file address for
    /// everything it is given, and a file that does not exist on disk is fine for it: it reads the
    /// text it was sent. Nil refuses such documents.
    public let virtualDirectory: URL?

    /// The `languageId` the server is told for a document, or nil if it is not a document for this
    /// server. By default what the file name says for Swift; the application replaces it with the
    /// document's language (`DocumentLanguageSelector`), which can be chosen by the user.
    public var languageID: @MainActor (DocumentSession) -> String? = { OrderedDocumentSync.languageID(forPath: $0.path) }

    public convenience init(
        limits: Limits = Limits(),
        capturePolicy: CapturePolicy = .standard,
        virtualDirectory: URL? = nil
    ) {
        self.init(limits: limits, capturePolicy: capturePolicy, virtualDirectory: virtualDirectory, capture: { try await $0.capture(policy: $1) })
    }

    init(limits: Limits, capturePolicy: CapturePolicy, virtualDirectory: URL? = nil, capture: @escaping Capture) {
        self.limits = limits
        self.capturePolicy = capturePolicy
        self.virtualDirectory = virtualDirectory
        self.capture = capture
    }

    /// The address of a document for the server.
    func address(of session: DocumentSession) -> String? {
        if session.isUntitled {
            guard let virtualDirectory else { return nil }

            // A server tells the language of a file by its name, so the stand-in has the right one.
            let name = "Untitled-\(session.id.rawValue.uuidString.prefix(8))." + Self.fileExtension(forLanguageID: languageID(session))

            return virtualDirectory.appendingPathComponent(name).absoluteString
        }

        return URL(fileURLWithPath: session.path).absoluteString
    }

    /// A change set from the session, as if it had just been published: for tests that need one
    /// the session would never produce.
    func receive(_ change: DocumentChangeSet, for session: DocumentSession) {
        if let entry = tracked[session.id] { changed(entry, change) }
    }

    // MARK: Connection

    /// Uses `connection` from now on and gives it every open document again, from the start: a new
    /// server knows nothing. Pass nil while there is no server; changes are then followed but not sent.
    public func attach(_ connection: LanguageServerConnection?) {
        generation += 1
        self.connection = connection
        guard connection != nil else { return }

        for entry in tracked.values { Task { await self.begin(entry) } }
    }

    // MARK: Documents

    public var openDocuments: [DocumentSession] { tracked.values.map(\.session) }

    public func isSynced(_ session: DocumentSession) -> Bool {
        guard let entry = tracked[session.id], case .synced = entry.phase else { return false }

        return entry.enqueuedVersion == session.version
    }

    public func uri(of session: DocumentSession) -> String? { tracked[session.id]?.uri }

    /// The position of `offset` in the text the server will have once its outbox is read, which is
    /// the document's current text when `isSynced`.
    public func position(of offset: Int, in session: DocumentSession) -> LSPPosition? {
        guard isSynced(session), let entry = tracked[session.id] else { return nil }

        return LSPPositionMapper.position(of: offset, in: entry.index)
    }

    /// The offset a server's position refers to, in the same text.
    public func offset(of position: LSPPosition, in session: DocumentSession) -> Int? {
        guard isSynced(session), let entry = tracked[session.id] else { return nil }

        return LSPPositionMapper.offset(of: position, in: entry.index)
    }

    /// Starts following `session` and tells the server about it. Returns when the server has been
    /// given the text (written to the outbox, not necessarily read).
    public func open(_ session: DocumentSession) async throws {
        guard tracked[session.id] == nil else { throw DocumentSyncError.alreadyOpen }

        guard address(of: session) != nil else { throw DocumentSyncError.untitled }

        guard languageID(session) != nil else { throw DocumentSyncError.unsupportedLanguage }

        guard session.utf16Length <= limits.maximumUTF16Length else {
            throw DocumentSyncError.tooLarge(utf16Length: session.utf16Length, limit: limits.maximumUTF16Length)
        }

        let entry = Tracked(session: session)
        tracked[session.id] = entry
        entry.changeSubscription = session.subscribeToChanges { [weak self, weak entry] change in
            guard let self, let entry else { return }

            self.changed(entry, change)
        }
        entry.saveSubscription = session.subscribeToSaves { [weak self, weak entry] in
            guard let self, let entry else { return }

            self.saved(entry)
        }
        await begin(entry)
    }

    public func close(_ session: DocumentSession) {
        guard let entry = tracked.removeValue(forKey: session.id) else { return }

        entry.epoch += 1
        if let id = entry.changeSubscription { session.unsubscribeFromChanges(id) }
        if let id = entry.saveSubscription { session.unsubscribeFromSaves(id) }
        closeOnServer(entry)
    }

    /// Tells the server the document is gone, if it has it: a document saved under another name
    /// was already closed at its old address, and one still being copied was never opened.
    private func closeOnServer(_ entry: Tracked) {
        guard entry.isOpenOnServer else { return }

        entry.isOpenOnServer = false
        connection?.notify("textDocument/didClose", ["textDocument": ["uri": .string(entry.uri)]])
    }

    // MARK: Giving a document to the server

    private func begin(_ entry: Tracked) async {
        guard tracked[entry.session.id] === entry else { return }

        entry.epoch += 1
        let epoch = entry.epoch
        entry.phase = .opening(buffered: [])
        let session = entry.session
        let capture: DocumentCapture
        do {
            capture = try await self.capture(session, capturePolicy)
        } catch {
            return   // cancelled; whoever cancelled decides what is next
        }
        // The scan of a large text is not the main thread's to do. Edits made meanwhile are kept.
        let text = capture.snapshot.text
        let index = await Task.detached(priority: .userInitiated) { LineIndex(text) }.value
        guard tracked[session.id] === entry, entry.epoch == epoch, case .opening(let buffered) = entry.phase else { return }

        entry.uri = address(of: session) ?? ""
        entry.index = index
        entry.enqueuedVersion = capture.snapshot.version
        entry.phase = .synced
        entry.isOpenOnServer = true
        connection?.notify("textDocument/didOpen", [
            "textDocument": [
                "uri": .string(entry.uri),
                "languageId": .string(languageID(session) ?? "swift"),
                "version": .int(Int(capture.snapshot.version)),
                "text": .string(capture.snapshot.text),
            ],
        ])
        // What was typed while the text was being copied follows it, in order.
        for change in buffered where change.newVersion > capture.snapshot.version {
            changed(entry, change)
        }
    }

    // MARK: Following changes

    private func changed(_ entry: Tracked, _ change: DocumentChangeSet) {
        switch entry.phase {
        case .opening(var buffered):
            buffered.append(change)
            entry.phase = .opening(buffered: buffered)

            return
        case .resyncing:
            return   // the full text that is waiting in the outbox covers this
        case .synced:
            break
        }
        guard let connection else { return }

        // Everything after this is decided now, synchronously, so that order is the order of edits.
        if change.oldVersion != entry.enqueuedVersion || connection.pendingOutbound >= limits.maximumPendingMessages {
            return scheduleResync(entry)
        }

        var contentChanges: [JSONValue] = []
        for edit in change.edits {   // descending: each range is valid in the text the edits before it leave
            contentChanges.append(Self.contentChange(for: edit, in: entry.index))
            guard entry.index.replace(edit.range, with: edit.replacement) else { return scheduleResync(entry) }
        }
        // The session's length is that of its latest version: only the latest change can be held
        // against it. A buffered one replayed after the opening is older than the session is.
        if change.newVersion == entry.session.version, entry.index.utf16Length != entry.session.utf16Length {
            return scheduleResync(entry)
        }

        entry.enqueuedVersion = change.newVersion
        connection.notify("textDocument/didChange", [
            "textDocument": ["uri": .string(entry.uri), "version": .int(Int(change.newVersion))],
            "contentChanges": .array(contentChanges),
        ])
    }

    private func scheduleResync(_ entry: Tracked) {
        guard let connection else { return }

        entry.phase = .resyncing
        resyncCount += 1
        let epoch = entry.epoch
        connection.notifyLater { [weak self, weak entry] in
            guard let self, let entry, self.tracked[entry.session.id] === entry, entry.epoch == epoch else { return nil }

            // On the main actor, at the moment of writing: the text and its version are of now, and
            // from here the index follows the document again.
            let snapshot = entry.session.snapshot()
            entry.index = LineIndex(snapshot.text)
            entry.enqueuedVersion = snapshot.version
            entry.phase = .synced

            return ("textDocument/didChange", [
                "textDocument": ["uri": .string(entry.uri), "version": .int(Int(snapshot.version))],
                "contentChanges": [["text": .string(snapshot.text)]],
            ])
        }
    }

    /// A Save As gives the document another address: the server is told it closed there and opened here.
    private func saved(_ entry: Tracked) {
        guard tracked[entry.session.id] === entry, let current = address(of: entry.session) else { return }

        guard case .synced = entry.phase, current != entry.uri else { return }

        closeOnServer(entry)
        Task { await self.begin(entry) }
    }

    /// The protocol has no position between the CR and the LF of one line terminator. An edit that
    /// begins or ends there is widened to take the whole terminator, and the character that was
    /// taken in is given back in the replacement, so the result is the same text.
    static func contentChange(for edit: DocumentEdit, in index: LineIndex) -> JSONValue {
        var start = edit.range.location
        var end = edit.range.location + edit.range.length
        var text = edit.replacement
        if isInsideCRLF(start, in: index) {
            start -= 1
            text = "\r" + text
        }

        if isInsideCRLF(end, in: index) {
            end += 1
            text += "\n"
        }

        return [
            "range": [
                "start": LSPPositionMapper.position(of: start, in: index).json,
                "end": LSPPositionMapper.position(of: end, in: index).json,
            ],
            "text": .string(text),
        ]
    }

    private static func isInsideCRLF(_ offset: Int, in index: LineIndex) -> Bool {
        guard offset > 0, offset < index.utf16Length else { return false }

        let line = index.line(containing: offset)
        let extent = index.lineExtent(line)

        return extent.terminator == .crlf && offset - index.startOffset(ofLine: line) == extent.content + 1
    }

    static func fileExtension(forLanguageID id: String?) -> String {
        switch id {
        case "c": "c"
        case "cpp": "cpp"
        case "objective-c": "m"
        case "objective-cpp": "mm"
        default: "swift"
        }
    }

    static func languageID(forPath path: String) -> String? {
        path.hasSuffix(".swift") ? "swift" : nil
    }
}
