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
    public var showExcluded = true { didSet { changed() } }
    public var showIgnored = true { didSet { changed() } }
    public var hasIgnoreInformation = false { didSet { changed() } }
    /// Supplied by TK-027. No Git result means unavailable, never an invented clean snapshot.
    public var decorations: [String: FileDecoration] = [:] { didSet { changed() } }
    public var statusExplanation = "Git status is not connected yet" { didSet { changed() } }
    public var unsavedPaths: Set<String> = [] { didSet { changed() } }
    public var onExclusionsChange: ((ProjectExclusions) -> Void)?

    private let reader: any ProjectDirectoryReading
    private var listings: [String: [ProjectFile]] = [:]
    private var states: [String: DirectoryState] = [:]
    private var defaults: [String: Set<String>] = [:]
    private var resolvedPaths: [String: String] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    private var generations: [String: UUID] = [:]
    private var observers: [UUID: () -> Void] = [:]

    public init(root: String, reader: any ProjectDirectoryReading, exclusions: ProjectExclusions = .init()) {
        self.root = DocumentPath.canonical(root)
        self.reader = reader
        self.exclusions = exclusions
    }

    public func state(of path: String) -> DirectoryState { states[path] ?? .idle }

    public func children(of path: String) -> [ProjectFile] {
        (listings[path] ?? []).filter {
            (showExcluded || exclusionReason(for: $0.path) == nil) && (showIgnored || decorations[$0.path]?.ignoredReason == nil)
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
        var value = decorations[path] ?? FileDecoration()
        value.exclusionReason = exclusionReason(for: path)
        value.isUnsaved = unsavedPaths.contains(resolvedPaths[path] ?? path)

        return value
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
        onExclusionsChange?(exclusions)
        changed()
    }

    public func include(_ path: String) {
        guard let rule = exclusionRoot(for: path), let name = relative(rule) else { return }

        exclusions.explicit.remove(name)
        exclusions.includedDefaults.insert(name)
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
