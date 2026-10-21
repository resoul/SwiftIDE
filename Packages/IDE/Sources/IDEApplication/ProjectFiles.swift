import Foundation

public struct ProjectFile: Equatable, Sendable {
    public let path: String
    public let isDirectory: Bool
    public let isSymbolicLink: Bool
    public let resolvedPath: String
    public var name: String { (path as NSString).lastPathComponent }
    public var canExpand: Bool { isDirectory && !isSymbolicLink }

    public init(path: String, isDirectory: Bool, isSymbolicLink: Bool = false, resolvedPath: String? = nil) {
        self.path = path
        self.isDirectory = isDirectory
        self.isSymbolicLink = isSymbolicLink
        self.resolvedPath = resolvedPath ?? path
    }
}

/// Reads one level, never a recursive inventory. The adapter performs disk work off the UI thread.
public protocol ProjectDirectoryReading: Sendable {
    func children(of path: String) async throws -> [ProjectFile]
}

public struct ProjectExclusions: Equatable, Codable, Sendable {
    /// Paths relative to the opened root. Git ignore rules are an independent input.
    public var explicit: Set<String>
    public var includedDefaults: Set<String>

    public init(explicit: Set<String> = [], includedDefaults: Set<String> = []) {
        self.explicit = explicit
        self.includedDefaults = includedDefaults
    }
}

public enum DirectoryState: Equatable, Sendable {
    case idle, loading, loaded, cancelled
    case failed(String)

    public var message: String? {
        switch self {
        case .idle: "Expand to load"
        case .loading: "Loading…"
        case .loaded: nil
        case .cancelled: "Loading cancelled — expand or refresh to retry"
        case .failed(let reason): "Could not read folder: \(reason)"
        }
    }
}

/// Shared by all views of an opened folder. Expanding, selection and exclusions survive tab changes.
@MainActor
public final class ProjectFiles {
    public let root: String
    public private(set) var exclusions: ProjectExclusions
    public private(set) var expanded: Set<String> = []
    public private(set) var selection: String?
    public var showExcluded = true { didSet { if oldValue != showExcluded { changed() } } }
    public var showIgnored = true { didSet { if oldValue != showIgnored { changed() } } }
    public var hasIgnoreInformation = false { didSet { if oldValue != hasIgnoreInformation { changed() } } }
    /// Supplied by TK-027. No Git result means unavailable, never an invented clean snapshot.
    public var decorations: [String: FileDecoration] = [:] { didSet { if oldValue != decorations { changed() } } }
    public var statusExplanation = "Git status is not connected yet" {
        didSet { if oldValue != statusExplanation { changed() } }
    }
    public var unsavedPaths: Set<String> = [] { didSet { if oldValue != unsavedPaths { changed() } } }
    public var onExclusionsChange: ((ProjectExclusions) -> Void)?
    public var onRefresh: (() -> Void)?

    private let reader: any ProjectDirectoryReading
    private var listings: [String: [ProjectFile]] = [:]
    private var states: [String: DirectoryState] = [:]
    private var defaults: [String: Set<String>] = [:]
    private var resolvedPaths: [String: String] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    private var generations: [String: UUID] = [:]
    private var observers: [UUID: () -> Void] = [:]
    private var gitSnapshot: GitSnapshot?

    private let creator: (any ProjectEntryCreating)?
    private let operations: (any ProjectItemOperating)?
    /// An item was renamed or moved on disk: the old and the new canonical path (a folder's whole
    /// subtree moved with it). The owner of the open documents retargets them.
    public var onItemRenamed: ((_ old: String, _ new: String) -> Void)?
    /// An item was moved to the Trash (canonical path before it went).
    public var onItemTrashed: ((_ path: String) -> Void)?
    /// Why items must not be changed now (for example a Git operation is running); nil when they may.
    public var blockedReason: (() -> String?)?

    public init(
        root: String,
        reader: any ProjectDirectoryReading,
        exclusions: ProjectExclusions = .init(),
        creator: (any ProjectEntryCreating)? = nil,
        operations: (any ProjectItemOperating)? = nil
    ) {
        self.root = DocumentPath.canonical(root)
        self.reader = reader
        self.exclusions = exclusions
        self.creator = creator
        self.operations = operations
    }

    /// Whether items can be renamed, duplicated and deleted from here.
    public var canModifyItems: Bool { operations != nil }

    /// How many open documents under `path` hold changes that are not saved.
    public func unsavedCount(under path: String) -> Int {
        let canonical = DocumentPath.canonical(path)

        return unsavedPaths.filter { $0 == canonical || $0.hasPrefix(canonical + "/") }.count
    }

    /// Renames `path`, keeps the tree's own state (expanded folders, selection, project exclusions)
    /// on the item and tells the owner so open documents follow. Returns the new path.
    @discardableResult
    public func rename(_ path: String, to name: String) throws -> String {
        let operations = try checkedOperations(for: path)
        let old = DocumentPath.canonical(path)
        let renamed = try operations.rename(path, to: name)
        guard renamed != path else { return path }

        let new = DocumentPath.canonical(renamed)
        moveState(from: path, to: renamed)
        remapExclusions(from: path, to: renamed)
        onItemRenamed?(old, new)
        select(renamed)
        refreshListings()

        return renamed
    }

    /// Copies `path` under `name` next to it. The copy has the saved file's content; unsaved
    /// changes in an open document are not part of it. Returns the copy's path.
    @discardableResult
    public func duplicate(_ path: String, as name: String) throws -> String {
        let copy = try checkedOperations(for: path).duplicate(path, as: name)
        select(copy)
        refreshListings()

        return copy
    }

    /// What a move or a copy of several items did: the new paths of those done, in order, and the
    /// reason it stopped, if it did. Items done before a failure stay done.
    public struct Transfer: Equatable {
        public var done: [String] = []
        public var failure: NewEntryError?
    }

    /// Moves items into `directory`. Open documents follow them (see `onItemRenamed`).
    public func move(_ paths: [String], into directory: String) -> Transfer {
        var transfer = Transfer()
        for path in paths {
            do {
                let operations = try checkedOperations(for: path)
                guard isInside(directory) else { throw NewEntryError.outsideProject }

                let old = DocumentPath.canonical(path)
                let moved = try operations.move(path, into: directory)
                if moved != path {
                    moveState(from: path, to: moved)
                    remapExclusions(from: path, to: moved)
                    onItemRenamed?(old, DocumentPath.canonical(moved))
                }

                transfer.done.append(moved)
            } catch {
                transfer.failure = error as? NewEntryError ?? .failed(error.localizedDescription)
                break
            }
        }
        finish(transfer)

        return transfer
    }

    /// Copies items into `directory`. A source outside the project (from Finder) is allowed.
    public func copy(_ paths: [String], into directory: String) -> Transfer {
        var transfer = Transfer()
        for path in paths {
            do {
                guard let operations else { throw NewEntryError.failed("this project cannot change files") }

                guard isInside(directory) else { throw NewEntryError.outsideProject }

                if let reason = blockedReason?() { throw NewEntryError.failed(reason) }

                transfer.done.append(try operations.copy(path, into: directory))
            } catch {
                transfer.failure = error as? NewEntryError ?? .failed(error.localizedDescription)
                break
            }
        }
        finish(transfer)

        return transfer
    }

    private func finish(_ transfer: Transfer) {
        guard let first = transfer.done.first else { return }

        let parent = (first as NSString).deletingLastPathComponent
        if isInside(parent) { expand(parent) }

        select(first)
        refreshListings()
    }

    /// Moves `path` to the Trash. The owner closes the open documents under it afterwards.
    public func trash(_ path: String) throws {
        let operations = try checkedOperations(for: path)
        let canonical = DocumentPath.canonical(path)
        try operations.trash(path)
        dropState(under: path)
        remapExclusions(from: path, to: nil)
        onItemTrashed?(canonical)
        refreshListings()
    }

    private func checkedOperations(for path: String) throws -> any ProjectItemOperating {
        guard let operations else { throw NewEntryError.failed("this project cannot change files") }

        guard isInside(path), path != root else { throw NewEntryError.isProjectFolder }

        if let reason = blockedReason?() { throw NewEntryError.failed(reason) }

        return operations
    }

    private func moved(_ candidate: String, from old: String, to new: String) -> String? {
        if candidate == old { return new }

        return candidate.hasPrefix(old + "/") ? new + candidate.dropFirst(old.count) : nil
    }

    private func moveState(from old: String, to new: String) {
        expanded = Set(expanded.map { moved($0, from: old, to: new) ?? $0 })
        if let selection, let target = moved(selection, from: old, to: new) { self.selection = target }
        for path in listings.keys + Array(tasks.keys) where moved(path, from: old, to: new) != nil {
            cancelAndForget(path)
        }
    }

    private func dropState(under path: String) {
        expanded = expanded.filter { moved($0, from: path, to: path) == nil }
        if let selection, moved(selection, from: path, to: path) != nil {
            self.selection = (path as NSString).deletingLastPathComponent
        }

        for key in Array(listings.keys) + Array(tasks.keys) where moved(key, from: path, to: path) != nil {
            cancelAndForget(key)
        }
    }

    private func cancelAndForget(_ path: String) {
        generations[path] = nil
        tasks.removeValue(forKey: path)?.cancel()
        listings[path] = nil
        states[path] = nil
        defaults[path] = nil
    }

    /// Project exclusions are kept by path relative to the root; an excluded item that moves keeps
    /// being excluded, and one that is deleted is forgotten.
    private func remapExclusions(from old: String, to new: String?) {
        guard let oldRelative = relative(old) else { return }

        let newRelative = new.flatMap { relative($0) }
        var explicit = Set<String>()
        for rule in exclusions.explicit {
            if rule == oldRelative || rule.hasPrefix(oldRelative + "/") {
                if let newRelative { explicit.insert(newRelative + rule.dropFirst(oldRelative.count)) }
            } else {
                explicit.insert(rule)
            }
        }
        if explicit != exclusions.explicit {
            exclusions.explicit = explicit
            onExclusionsChange?(exclusions)
        }
    }

    /// Whether new files and folders can be made from here.
    public var canCreate: Bool { creator != nil }

    /// Makes a new file or folder inside `directory`, shows it in the tree and selects it.
    /// Returns its path. The caller reports an error and decides what to open.
    @discardableResult
    public func create(_ kind: NewEntryKind, named name: String, in directory: String) throws -> String {
        guard let creator else { throw NewEntryError.failed("this project cannot create files") }

        guard isInside(directory) else { throw NewEntryError.outsideProject }

        let created = try creator.create(kind, named: name, in: directory)
        // Every folder from the one asked for down to the new item shows what is now in it.
        var shown = directory
        let below = created.dropFirst(directory.count).split(separator: "/").dropLast()
        var folders = [directory]
        for part in below {
            shown += "/" + part
            folders.append(shown)
        }
        for folder in folders { expand(folder) }
        for folder in folders where expanded.contains(folder) && state(of: folder) == .loaded {
            load(folder, replacing: true)
        }

        select(created)

        return created
    }

    public func state(of path: String) -> DirectoryState { states[path] ?? .idle }

    /// A successful empty listing is distinct from a folder that has never loaded.
    public func hasListing(of path: String) -> Bool { listings[path] != nil }

    public func children(of path: String) -> [ProjectFile] {
        (listings[path] ?? []).filter {
            (showExcluded || exclusionReason(for: $0.path) == nil) &&
                (showIgnored || gitDecoration(for: $0.path).ignoredReason == nil)
        }
    }

    public func select(_ path: String?) {
        guard selection != path else { return }

        selection = path
        changed()
    }

    public func expand(_ path: String) {
        guard isInside(path) else { return }

        expanded.insert(path)
        if state(of: path) != .loaded { load(path) } else { changed() }
    }

    public func collapse(_ path: String) {
        expanded.remove(path)
        if tasks[path] != nil { cancel(path) }
        changed()
    }

    /// Only directories that have been expanded are refreshed. No recursive scan for exclusions.
    public func refresh() {
        refreshListings()
        onRefresh?()
    }

    /// Refresh directory rows after an external status provider completes, without requesting it again.
    public func refreshListings() {
        for path in expanded { load(path, replacing: true) }
    }

    public func stop() {
        for path in Array(tasks.keys) { cancel(path) }
        changed()
    }

    private func cancel(_ path: String) {
        generations[path] = nil
        tasks.removeValue(forKey: path)?.cancel()
        states[path] = .cancelled
    }

    private func load(_ path: String, replacing: Bool = false) {
        if !replacing, tasks[path] != nil { return }
        tasks[path]?.cancel()
        let generation = UUID()
        generations[path] = generation
        states[path] = .loading
        tasks[path] = Task { [weak self, reader] in
            do {
                let entries = try await reader.children(of: path)
                guard let self, !Task.isCancelled, generations[path] == generation else { return }

                // Refuse malformed adapter results, including grandchildren and duplicate paths.
                let direct = entries.filter { ($0.path as NSString).deletingLastPathComponent == path }
                var seen: Set<String> = []
                for entry in direct { resolvedPaths[entry.path] = entry.resolvedPath }
                listings[path] = direct.filter { seen.insert($0.path).inserted }.sorted {
                    if $0.isDirectory != $1.isDirectory { return $0.isDirectory }

                    return $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
                // The marker is observed in the listing; no manifest is executed and no build tree is walked.
                let isPackage = direct.contains { $0.name == "Package.swift" && !$0.isDirectory }
                defaults[path] = isPackage ? [path + "/.build"] : []
                rebuildGitDecorations()
                states[path] = .loaded
            } catch {
                guard let self, generations[path] == generation else { return }

                states[path] = error is CancellationError ? .cancelled : .failed(error.localizedDescription)
            }
            guard let self, generations[path] == generation else { return }

            tasks[path] = nil
            changed()
        }
        changed()
    }

    public func decoration(for path: String) -> FileDecoration {
        var value = gitDecoration(for: path)
        value.exclusionReason = exclusionReason(for: path)
        value.isUnsaved = unsavedPaths.contains(resolvedPaths[path] ?? path)

        return value
    }

    public func applyGitSnapshot(_ snapshot: GitSnapshot) {
        gitSnapshot = snapshot
        rebuildGitDecorations()
    }

    private func rebuildGitDecorations() {
        guard let gitSnapshot else { return }

        let values = gitSnapshot.decorations(exclusionReason: { self.exclusionReason(for: $0) })
        if values != decorations { decorations = values }
    }

    private func gitDecoration(for path: String) -> FileDecoration {
        if let direct = decorations[path] { return direct }

        var parent = (path as NSString).deletingLastPathComponent
        while parent == root || parent.hasPrefix(root + "/") {
            if let ignored = decorations[parent]?.ignoredReason { return FileDecoration(ignoredReason: ignored) }
            if parent == root { break }
            parent = (parent as NSString).deletingLastPathComponent
        }

        return FileDecoration()
    }

    private func relative(_ path: String) -> String? {
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard path.hasPrefix(prefix) else { return nil }

        return String(path.dropFirst(prefix.count))
    }

    private func isInside(_ path: String) -> Bool { path == root || relative(path) != nil }

    private func holds(_ parent: String, _ child: String) -> Bool { child == parent || child.hasPrefix(parent + "/") }

    /// The root whose rule applies, so Include removes the rule rather than a meaningless child override.
    public func exclusionRoot(for path: String) -> String? {
        guard let relative = relative(path) else { return nil }

        if let rule = exclusions.explicit.filter({ holds($0, relative) }).min(by: { $0.count < $1.count }) {
            return root + "/" + rule
        }

        return defaults.values.flatMap { $0 }.filter {
            holds($0, path) && !exclusions.includedDefaults.contains(self.relative($0) ?? "")
        }.min(by: { $0.count < $1.count })
    }

    public func exclusionReason(for path: String) -> String? {
        guard let rule = exclusionRoot(for: path), let name = relative(rule) else { return nil }

        return exclusions.explicit.contains(name)
            ? "Excluded from project: \(name) (project setting)"
            : "Excluded from project: \(name) (SwiftPM build artifacts)"
    }

    public func exclude(_ path: String) {
        guard let name = relative(path), exclusionRoot(for: path) == nil else { return }

        exclusions.explicit.insert(name)
        rebuildGitDecorations()
        onExclusionsChange?(exclusions)
        changed()
    }

    public func include(_ path: String) {
        guard let rule = exclusionRoot(for: path), let name = relative(rule) else { return }

        exclusions.explicit.remove(name)
        exclusions.includedDefaults.insert(name)
        rebuildGitDecorations()
        onExclusionsChange?(exclusions)
        changed()
    }

    @discardableResult
    public func subscribe(_ observer: @escaping () -> Void) -> UUID {
        let id = UUID()
        observers[id] = observer

        return id
    }

    public func unsubscribe(_ id: UUID) { observers[id] = nil }

    private func changed() { for observer in Array(observers.values) { observer() } }
}
