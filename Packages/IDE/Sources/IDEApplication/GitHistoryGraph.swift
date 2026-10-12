import Foundation

public struct GitGraphEdge: Equatable, Sendable {
    public let from: Int
    public let to: Int
    public let incoming: Bool
    public let colour: Int
}

public struct GitGraphRow: Equatable, Sendable {
    public let lane: Int
    public let colour: Int
    public let lanes: Int
    public let edges: [GitGraphEdge]
}

/// Recompute from the immutable loaded prefix; adding a page preserves earlier lane assignments.
public enum GitHistoryGraph {
    public static func layout(_ commits: [GitCommit]) -> [String: GitGraphRow] {
        var pending: [String] = [], colours: [String: Int] = [:], nextColour = 0
        var result: [String: GitGraphRow] = [:]
        for commit in commits {
            let hasIncoming = pending.contains(commit.oid)
            if !hasIncoming { pending.append(commit.oid) }
            let before = pending
            let lane = pending.firstIndex(of: commit.oid) ?? 0
            if colours[commit.oid] == nil {
                colours[commit.oid] = nextColour
                nextColour += 1
            }

            let colour = colours[commit.oid] ?? 0
            pending.remove(at: lane)
            var slot = lane
            for (index, parent) in commit.parents.enumerated() {
                if colours[parent] == nil {
                    colours[parent] = index == 0 ? colour : nextColour
                    if index != 0 { nextColour += 1 }
                }

                if !pending.contains(parent) {
                    pending.insert(parent, at: min(slot, pending.count))
                    slot += 1
                }
            }
            var edges: [GitGraphEdge] = []
            for (index, oid) in before.enumerated() {
                let key = colours[oid] ?? index
                if oid != commit.oid || hasIncoming {
                    edges.append(.init(from: index, to: index, incoming: true, colour: key))
                }

                if oid != commit.oid, let target = pending.firstIndex(of: oid) {
                    edges.append(.init(from: index, to: target, incoming: false, colour: key))
                }
            }
            for parent in commit.parents {
                if let target = pending.firstIndex(of: parent) {
                    edges.append(.init(from: lane, to: target, incoming: false, colour: colours[parent] ?? colour))
                }
            }
            result[commit.oid] = .init(
                lane: lane,
                colour: colour,
                lanes: max(before.count, pending.count),
                edges: edges
            )
        }

        return result
    }
}
