import IDEApplication

/// Display wording and priority for project readiness. Policy and state remain in IDEApplication.
public extension ProjectReadiness {
    /// The one thing most worth saying, or nil when there is nothing to say (an unknown state is
    /// not announced: it would be on every window).
    var reason: String? {
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
