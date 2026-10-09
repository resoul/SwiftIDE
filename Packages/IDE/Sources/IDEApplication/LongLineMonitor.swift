import Foundation

/// How long a line may be before editing it is no longer comfortable (ADR-015).
public struct LongLinePolicy: Sendable, Equatable {
    /// A line longer than this (UTF-16 units, without its terminator) is a long line. TextKit lays
    /// out a whole line at once, and typing in a plain line costs about 9 ms at 12 000 characters,
    /// 15 ms at 16 000 and 33 ms at 24 000 (docs/benchmarks/TK-012-long-lines.md).
    public var threshold: Int

    public init(threshold: Int = 16_000) {
        self.threshold = threshold
    }

    public static let standard = LongLinePolicy()
}

/// Watches a document for lines too long to edit comfortably and says so once.
///
/// It asks the line index for the longest line after every change; that costs a step per chunk of
/// lines, not per line. The warning stays until the line gets short again or the user dismisses
/// it; a dismissed warning does not come back for that document.
@MainActor
public final class LongLineMonitor {
    public enum State: Equatable, Sendable {
        case normal
        case warning
        case dismissed
    }

    public private(set) var state: State = .normal
    /// Length of the longest line when last looked at.
    public private(set) var longestLength = 0
    public var onChange: (@MainActor (State) -> Void)?

    private let lineIndex: DocumentLineIndex
    private let policy: LongLinePolicy
    private var subscription: UUID?

    public init(lineIndex: DocumentLineIndex, policy: LongLinePolicy = .standard) {
        self.lineIndex = lineIndex
        self.policy = policy
        look()
        subscription = lineIndex.subscribe { [weak self] in self?.look() }
    }

    isolated deinit {
        if let subscription { lineIndex.unsubscribe(subscription) }
    }

    /// The user chose to go on: no more warnings for this document.
    public func dismiss() {
        guard state != .dismissed else { return }
        state = .dismissed
        onChange?(state)
    }

    private func look() {
        longestLength = lineIndex.current.longestLine.length
        guard state != .dismissed else { return }
        let wanted: State = longestLength > policy.threshold ? .warning : .normal
        guard wanted != state else { return }
        state = wanted
        onChange?(state)
    }
}
