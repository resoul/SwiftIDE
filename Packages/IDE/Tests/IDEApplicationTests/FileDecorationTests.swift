import IDEApplication
import Testing

struct FileDecorationTests {
    @Test func precedencePreservesIndependentBadgesAndReasons() {
        let combined = FileDecoration(index: "A", worktree: "M", isConflict: true, exclusionReason: "project setting", isUnsaved: true)
        #expect(combined.tone == .orange)
        #expect(combined.badges == "⚠︎ A M ●")
        #expect(combined.explanation.contains("Conflict") && combined.explanation.contains("Unsaved"))
        #expect(FileDecoration(isConflict: true).tone == .red)
        #expect(FileDecoration(index: "A", worktree: "M").tone == .blue)
        #expect(FileDecoration(index: "A").tone == .green)
        #expect(FileDecoration(isUntracked: true).tone == .red)
        #expect(FileDecoration(isUnsaved: true).tone == .normal)
        #expect(FileDecoration(index: "R").tone == .blue)
        #expect(FileDecoration(worktree: "D").tone == .blue)
        #expect(FileDecoration(isUntracked: true, ignoredReason: "rule").badges.isEmpty)
    }

    @Test func foldersAggregateChangesWithoutInheritingExclusionAlone() {
        #expect(FileDecoration.aggregate([.init(exclusionReason: "build"), .init(ignoredReason: "rule")]).tone == .normal)
        #expect(FileDecoration.aggregate([.init(isUntracked: true, exclusionReason: "build")]).tone == .normal)
        #expect(FileDecoration.aggregate([.init(index: "A")]).tone == .green)
        #expect(FileDecoration.aggregate([.init(isUntracked: true)]).tone == .red)
        let mixed = FileDecoration.aggregate([.init(index: "A"), .init(isUntracked: true)])
        #expect(mixed.tone == .blue && mixed.explanation.contains("Mixed changes"))
        #expect(FileDecoration.aggregate([.init(worktree: "M", exclusionReason: "project")]).tone == .blue)
        #expect(FileDecoration.aggregate([.init(isConflict: true, ignoredReason: "rule")]).isConflict)
    }
}
