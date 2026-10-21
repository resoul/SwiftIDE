import Foundation

/// The files of a project folder, as paths relative to it.
public struct ProjectFileList: Sendable, Equatable {
    public var paths: [String]
    /// The folder held more files than were listed.
    public var isTruncated: Bool

    public init(paths: [String], isTruncated: Bool = false) {
        self.paths = paths
        self.isTruncated = isTruncated
    }
}

/// Lists every file of a project folder. Reading the disk is the adapter's matter.
public protocol ProjectFileLister: Sendable {
    func listFiles(under root: String) async -> ProjectFileList
}

/// A file found by name.
public struct QuickOpenResult: Sendable, Equatable, Identifiable {
    /// The path relative to the project root.
    public let path: String
    public var id: String { path }
    public var name: String { (path as NSString).lastPathComponent }
    /// The folder the file is in, relative to the root; empty at the top level.
    public var directory: String { (path as NSString).deletingLastPathComponent }

    public init(path: String) { self.path = path }
}

/// Finding files by a few typed letters.
public enum FileSearch {
    /// A path prepared for matching, so that a keystroke does not re-derive it for every file.
    public struct Entry: Sendable {
        let path: String
        let lowered: [UInt8]
        let nameStart: Int
        /// Whether the byte starts a word: the first one, one after a separator, or a capital letter.
        let boundaries: [Bool]

        public init(path: String) {
            self.path = path
            let original = Array(path.utf8)
            lowered = Array(path.lowercased().utf8)
            nameStart = (original.lastIndex(of: 0x2F)).map { $0 + 1 } ?? 0
            boundaries = original.indices.map { index in
                guard index > 0 else { return true }

                let previous = original[index - 1]
                if [0x2F, 0x2E, 0x5F, 0x2D, 0x20].contains(previous) { return true }

                return original[index] >= 0x41 && original[index] <= 0x5A && previous >= 0x61 && previous <= 0x7A
            }
        }
    }

    /// The files whose path holds the query's letters in order (spaces ignored), best first. A match
    /// inside the file name beats one in the folders, and runs of letters and word starts score
    /// higher. With no query the first `limit` entries are returned unchanged.
    public static func rank(_ query: String, in entries: [Entry], limit: Int = 100) -> [QuickOpenResult] {
        let needle = Array(query.lowercased().utf8).filter { $0 != 0x20 }
        guard !needle.isEmpty else { return entries.prefix(limit).map { QuickOpenResult(path: $0.path) } }

        var scored: [(score: Int, index: Int)] = []
        for (index, entry) in entries.enumerated() {
            if let score = score(needle, in: entry) { scored.append((score, index)) }
        }
        scored.sort { ($1.score, $0.index) < ($0.score, $1.index) }

        return scored.prefix(limit).map { QuickOpenResult(path: entries[$0.index].path) }
    }

    private static func score(_ needle: [UInt8], in entry: Entry) -> Int? {
        let text = entry.lowered
        // Cheap rejection first: the letters must appear in order somewhere.
        var position = 0
        for byte in needle {
            guard let found = text[position...].firstIndex(of: byte) else { return nil }

            position = found + 1
        }

        // Prefer a match that lies inside the file name; then take the best over the whole path.
        let inName = match(needle, in: entry, from: entry.nameStart)
        let overall = match(needle, in: entry, from: 0)

        return [inName.map { $0 + 200 }, overall].compactMap { $0 }.max()
    }

    /// Greedy forward match from `start` that restarts on a word boundary to find a tighter run.
    private static func match(_ needle: [UInt8], in entry: Entry, from start: Int) -> Int? {
        let text = entry.lowered
        var best: Int?
        for first in start..<text.count where text[first] == needle[0] {
            var position = first
            var score = 10 + (entry.boundaries[first] ? 30 : 0) + (first == entry.nameStart ? 20 : 0)
            var matched = 1
            while matched < needle.count {
                guard let next = text[(position + 1)...].firstIndex(of: needle[matched]) else {
                    score = -1
                    break
                }

                if next == position + 1 {
                    score += 15
                } else {
                    score += entry.boundaries[next] ? 8 : -min(6, next - position)
                }

                position = next
                matched += 1
            }
            if score >= 0, score > (best ?? -1) { best = score }

            // A run that starts at a word boundary is the best a later start in this word can do.
            if best != nil, entry.boundaries[first] { break }
        }

        return best.map { $0 - entry.lowered.count / 8 }
    }
}

/// What the Quick Open window needs about one project: the files, found in the background, and the
/// ones opened recently. It reads the disk only through its lister and only when asked to.
@MainActor
public final class QuickOpen {
    public enum State: Equatable, Sendable {
        case idle
        case loading
        case ready(truncated: Bool)
    }

    public let root: String
    public private(set) var state = State.idle
    /// Called when the file list or the state changed.
    public var onChange: (() -> Void)?

    private let lister: any ProjectFileLister
    private let isExcluded: @MainActor (String) -> Bool
    private var entries: [FileSearch.Entry] = []
    private var recent: [String] = []
    private var task: Task<Void, Never>?
    private static let recentLimit = 20

    public init(
        root: String,
        lister: any ProjectFileLister,
        isExcluded: @escaping @MainActor (String) -> Bool = { _ in false }
    ) {
        self.root = root
        self.lister = lister
        self.isExcluded = isExcluded
    }

    public var fileCount: Int { entries.count }

    /// Lists the files again. A listing already running is replaced.
    public func reload() {
        task?.cancel()
        state = .loading
        onChange?()
        let root = root, lister = lister
        task = Task { [weak self] in
            let list = await lister.listFiles(under: root)
            guard !Task.isCancelled, let self else { return }

            let kept = list.paths.filter { !isExcluded(root + "/" + $0) }
            entries = kept.map(FileSearch.Entry.init)
            state = .ready(truncated: list.isTruncated)
            onChange?()
        }
    }

    /// A file was opened: it comes first in the list the next time the window is empty.
    public func noteOpened(_ path: String) {
        guard path.hasPrefix(root + "/") else { return }

        let relative = String(path.dropFirst(root.count + 1))
        recent.removeAll { $0 == relative }
        recent.insert(relative, at: 0)
        if recent.count > Self.recentLimit { recent.removeLast(recent.count - Self.recentLimit) }
    }

    /// The files for what is typed. With nothing typed: the recently opened ones that still exist in
    /// the listing, then the rest in listing order.
    public func results(for query: String, limit: Int = 100) -> [QuickOpenResult] {
        guard query.allSatisfy({ $0.isWhitespace }) else { return FileSearch.rank(query, in: entries, limit: limit) }

        let known = Set(entries.map(\.path))
        let first = recent.filter { known.contains($0) }
        let rest = entries.lazy.map(\.path).filter { !first.contains($0) }

        return (first + rest.prefix(max(0, limit - first.count))).map { QuickOpenResult(path: $0) }
    }

    /// Stops listing. The model is not used again after the project closes.
    public func stop() {
        task?.cancel()
        task = nil
        onChange = nil
        state = .idle
    }
}
