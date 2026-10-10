import Foundation

// MARK: Work the server reports

/// "2 / 5", as the server sent it.
public struct ProgressCounts: Equatable, Sendable {
    public let done: Int
    public let total: Int

    public init(done: Int, total: Int) {
        self.done = done
        self.total = total
    }

    /// Reads a message that is exactly "n / m". Anything else gives no numbers: they are shown only
    /// when the server sent them.
    static func parse(_ message: String?) -> ProgressCounts? {
        guard let message else { return nil }

        let parts = message.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let done = Int(parts[0].trimmingCharacters(in: .whitespaces)),
              let total = Int(parts[1].trimmingCharacters(in: .whitespaces)),
              done >= 0, total >= 0 else { return nil }

        return ProgressCounts(done: done, total: total)
    }
}

public enum ProgressEvent: Equatable, Sendable {
    case begin(title: String, message: String?, percentage: Int?)
    case report(message: String?, percentage: Int?)
    case end
}

/// One operation the server reports with `$/progress`.
public struct ProgressOperation: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// SourceKit-LSP loading the package's settings.
        case packageReload
        /// SourceKit-LSP preparing targets and indexing.
        case indexing
        case other
    }

    public let token: String
    public private(set) var title: String
    public private(set) var message: String?
    public private(set) var percentage: Int?
    public private(set) var counts: ProgressCounts?

    public var kind: Kind {
        if token.hasPrefix("package-reloading.") { return .packageReload }
        if token.hasPrefix("indexing.") { return .indexing }

        return .other
    }

    public var isPreparation: Bool { kind != .other }

    init(token: String, title: String, message: String?, percentage: Int?) {
        self.token = token
        self.title = title
        update(message: message, percentage: percentage)
    }

    mutating func update(message: String?, percentage: Int?) {
        // The newest message decides what the numbers are: "Preparing current file" after "2 / 5"
        // leaves no numbers rather than stale ones.
        if let message {
            self.message = message
            counts = ProgressCounts.parse(message)
        }

        if let percentage { self.percentage = percentage }
    }
}

/// The operations a server is running, from its `$/progress` notifications. Several run at once;
/// each ends by itself; a report or an end for one that never began is ignored; a restart forgets
/// them all. What is tracked is work in progress, not readiness: the end of one proves nothing
/// about the files.
public struct ProgressTracker: Equatable, Sendable {
    public private(set) var operations: [ProgressOperation] = []
    /// A preparation (package reload or indexing) has begun and, later, none is left running.
    public private(set) var hasCompletedInitialPreparation = false
    private var hasSeenPreparation = false

    public init() {}

    public var isIdle: Bool { operations.isEmpty }

    /// The first preparation after the server started is going on. Nothing seen yet is not it:
    /// the absence of events proves neither that it has begun nor that it is over.
    public var isInitialPreparation: Bool {
        !hasCompletedInitialPreparation && operations.contains(where: \.isPreparation)
    }

    public mutating func apply(token: String, _ event: ProgressEvent) {
        switch event {
        case .begin(let title, let message, let percentage):
            operations.removeAll { $0.token == token }
            let operation = ProgressOperation(token: token, title: title, message: message, percentage: percentage)
            operations.append(operation)
            if operation.isPreparation { hasSeenPreparation = true }
        case .report(let message, let percentage):
            guard let index = operations.firstIndex(where: { $0.token == token }) else { return }

            operations[index].update(message: message, percentage: percentage)
        case .end:
            guard let index = operations.firstIndex(where: { $0.token == token }) else { return }

            operations.remove(at: index)
            if hasSeenPreparation, !operations.contains(where: \.isPreparation) { hasCompletedInitialPreparation = true }
        }
    }

    /// The server went away: whatever it was doing is not being done.
    public mutating func reset() {
        self = ProgressTracker()
    }
}

// MARK: Readiness

public enum ServerStatus: Equatable, Sendable {
    case stopped, starting, running, restarting, failed
}

public enum SettingsStatus: Equatable, Sendable {
    /// No signal either way. The default: no event proves readiness or fallback.
    case unknown
    case loading
    /// Only an explicit, reliable signal that the project's flags were received sets this. SourceKit-LSP
    /// sends none for SwiftPM, so nothing reaches it yet.
    case prepared
    /// The document is known to have no project: its settings are the server's defaults.
    case fallback
}

public enum ConfigurationTrust: Equatable, Sendable {
    case undecided, granted, refused
}

/// What a diagnostic report was made on top of.
public enum DiagnosticsBasis: Equatable, Sendable {
    /// With project settings that were confirmed. Nothing confirms them yet.
    case confirmed
    /// With settings nobody confirmed (readiness unknown): shown as they come.
    case unconfirmed
    /// While the initial preparation was going on: may name a module that is not ready yet.
    case preparing
    /// With the server's default settings, because there is no project.
    case fallback
}

/// Whether the server is up, whether the document's settings are known, what is going on in the
/// background and whether the project's configuration may be used: independent things, kept apart,
/// with one reason to show.
public struct ProjectReadiness: Equatable, Sendable {
    public var server: ServerStatus
    public var settings: SettingsStatus
    public var operations: [ProgressOperation]
    public var trust: ConfigurationTrust
    public var isAskingForTrust: Bool
    public var isInitialPreparation: Bool

    public static func make(
        server: ServerStatus,
        isFallbackRoot: Bool,
        progress: ProgressTracker,
        trust: ConfigurationTrust,
        isAskingForTrust: Bool = false
    ) -> ProjectReadiness {
        let settings: SettingsStatus
        if isFallbackRoot {
            settings = .fallback
        } else if progress.operations.contains(where: { $0.kind == .packageReload }) {
            settings = .loading
        } else {
            settings = .unknown
        }

        return ProjectReadiness(
            server: server,
            settings: settings,
            operations: progress.operations,
            trust: trust,
            isAskingForTrust: isAskingForTrust,
            isInitialPreparation: progress.isInitialPreparation
        )
    }

    public var diagnosticsBasis: DiagnosticsBasis {
        switch settings {
        case .fallback: .fallback
        case .prepared: .confirmed
        case .unknown, .loading: isInitialPreparation ? .preparing : .unconfirmed
        }
    }

    /// The one thing most worth saying, or nil when there is nothing to say (an unknown state is
    /// not announced: it would be on every window).
    public var reason: String? {
        switch server {
        case .failed: return "Language server failed"
        case .restarting: return "Language server restarting"
        case .starting: return "Language server starting"
        case .stopped, .running: break
        }

        if isAskingForTrust { return "Waiting for your decision on the project configuration" }

        if let work = workDescription { return work }

        if trust == .refused { return "Project configuration disabled" }

        if settings == .fallback { return "Using fallback settings" }

        return nil
    }

    private var workDescription: String? {
        let preparing = operations.filter(\.isPreparation)
        if !preparing.isEmpty {
            let withCounts = preparing.first(where: { $0.counts != nil })
            let onlyReloading = preparing.allSatisfy { $0.kind == .packageReload }
            let words = onlyReloading && withCounts == nil ? "Reloading package" : "Preparing package"

            return Self.join(words, withCounts?.counts)
        }

        guard let other = operations.first(where: { $0.counts != nil }) ?? operations.first else { return nil }

        return Self.join(other.title, other.counts)
    }

    private static func join(_ words: String, _ counts: ProgressCounts?) -> String {
        guard let counts else { return words }

        return "\(words) · \(counts.done) / \(counts.total)"
    }
}

// MARK: Trust

public enum TrustDecision: String, Sendable {
    case granted, refused
}

/// What the user decided about a project's configuration (SourceKit-LSP's `.sourcekit-lsp/` and
/// `.bsp/`), kept by the application under the canonical root. The repository has no way to write
/// here: only the user's answer does.
@MainActor
public protocol ProjectTrustStore: AnyObject {
    func decision(forRoot root: String) -> TrustDecision?
    func record(_ decision: TrustDecision, forRoot root: String)
    func forget(root: String)
}

@MainActor
public final class MemoryProjectTrustStore: ProjectTrustStore {
    private var decisions: [String: TrustDecision] = [:]

    public init() {}

    public func decision(forRoot root: String) -> TrustDecision? { decisions[root] }

    public func record(_ decision: TrustDecision, forRoot root: String) { decisions[root] = decision }

    public func forget(root: String) { decisions.removeValue(forKey: root) }
}

/// Asks the user whether the project's configuration may be used. Never called twice for one root
/// once an answer is kept.
public typealias TrustPrompt = @MainActor (_ projectName: String, _ root: URL) async -> TrustDecision
