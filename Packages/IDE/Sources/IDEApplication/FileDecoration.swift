import Foundation

public enum FileNameTone: Sendable { case normal, red, green, blue, orange }

/// Presentation input, independent of any Git porcelain format. Index and worktree badges stay separate.
public struct FileDecoration: Equatable, Sendable {
    public var index: String
    public var worktree: String
    public var isUntracked: Bool
    public var isConflict: Bool
    public var ignoredReason: String?
    public var exclusionReason: String?
    public var isUnsaved: Bool
    public var isMixed: Bool

    public init(
        index: String = "",
        worktree: String = "",
        isUntracked: Bool = false,
        isConflict: Bool = false,
        ignoredReason: String? = nil,
        exclusionReason: String? = nil,
        isUnsaved: Bool = false,
        isMixed: Bool = false
    ) {
        self.index = index
        self.worktree = worktree
        self.isUntracked = isUntracked
        self.isConflict = isConflict
        self.ignoredReason = ignoredReason
        self.exclusionReason = exclusionReason
        self.isUnsaved = isUnsaved
        self.isMixed = isMixed
    }

    public var tone: FileNameTone {
        if exclusionReason != nil || ignoredReason != nil { return .orange }
        if isConflict { return .red }
        if isMixed || !worktree.isEmpty || (!index.isEmpty && index != "A") { return .blue }
        if index == "A" { return .green }
        if isUntracked { return .red }

        return .normal
    }

    public var badges: String {
        [isConflict ? "⚠︎" : nil,
         index.isEmpty ? nil : index,
         worktree.isEmpty ? nil : worktree,
         isUntracked && ignoredReason == nil ? "?" : nil,
         isUnsaved ? "●" : nil].compactMap { $0 }.joined(separator: " ")
    }

    public var explanation: String {
        [exclusionReason,
         ignoredReason.map { "Ignored by Git: \($0)" },
         isConflict ? "Conflict" : nil,
         index.isEmpty ? nil : "Index: \(index)",
         worktree.isEmpty ? nil : "Working tree: \(worktree)",
         isUntracked && ignoredReason == nil ? "Untracked" : nil,
         isMixed ? "Mixed changes" : nil,
         isUnsaved ? "Unsaved editor changes" : nil].compactMap { $0 }.joined(separator: " · ")
    }

    /// An exclusion/ignore alone does not colour the parent. Tracked changes remain independent of exclusions.
    public static func aggregate(_ descendants: [Self]) -> Self {
        let conflict = descendants.contains { $0.isConflict }
        let modified = descendants.contains { !$0.worktree.isEmpty || (!$0.index.isEmpty && $0.index != "A") || $0.isMixed }
        let added = descendants.contains { $0.index == "A" }
        let untracked = descendants.contains { $0.isUntracked && $0.ignoredReason == nil && $0.exclusionReason == nil }

        return Self(index: added ? "A" : "",
                    worktree: modified ? "M" : "",
                    isUntracked: untracked,
                    isConflict: conflict,
                    isMixed: added && untracked)
    }
}
