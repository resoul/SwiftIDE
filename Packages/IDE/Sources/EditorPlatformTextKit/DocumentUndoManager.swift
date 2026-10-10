import Foundation

/// The document's UndoManager. It decides who owns an undo group before touching one.
///
/// With `groupsByEvent` the run loop keeps one implicit group open per event, and NSTextView
/// registers typing into it. A programmatic step in the same event would merge with the typing,
/// so at the moment a step is *actually registered* the implicit group is closed and a fresh one
/// opened for it. Nothing is opened or closed in advance, so a step that never registers leaves
/// no empty group behind.
///
/// Ownership: only groups the system opened (inside a registration, undo or redo) may be
/// closed here. A group opened by calling `beginUndoGrouping()` from outside belongs to that
/// caller; while one is open, steps simply join it and pairing is never disturbed.
///
/// Touched on the main thread only; AppKit calls these overrides there.
final class DocumentUndoManager: UndoManager, @unchecked Sendable {
    private enum Owner { case system, caller }

    nonisolated(unsafe) private var groups: [Owner] = []
    nonisolated(unsafe) private var isRegistering = false
    nonisolated(unsafe) private var boundaryPending = false

    // MARK: Group bookkeeping

    override func beginUndoGrouping() {
        alignGroups()
        groups.append(isRegistering || isUndoing || isRedoing ? .system : .caller)
        super.beginUndoGrouping()
    }

    override func endUndoGrouping() {
        alignGroups()
        if !groups.isEmpty { groups.removeLast() }
        super.endUndoGrouping()
    }

    /// Groups can also open and close inside AppKit without passing through the overrides.
    /// If the record disagrees with the real nesting, unknown groups count as the caller's.
    private func alignGroups() {
        let level = groupingLevel
        if groups.count > level { groups.removeLast(groups.count - level) }
        while groups.count < level { groups.append(.caller) }
    }

    // MARK: Registration

    /// The path NSTextView uses for typing, cut, paste and delete.
    override func registerUndo(withTarget target: Any, selector: Selector, object anObject: Any?) {
        separateIfNeeded(force: false)
        isRegistering = true
        super.registerUndo(withTarget: target, selector: selector, object: anObject)
        isRegistering = false
        boundaryPending = false
    }

    /// A programmatic step: always its own undo step, and the next typing is separated from it.
    func registerProgrammatic<Target: AnyObject>(
        target: Target,
        handler: @escaping @Sendable (Target) -> Void
    ) {
        separateIfNeeded(force: true)
        isRegistering = true
        registerUndo(withTarget: target, handler: handler)
        isRegistering = false
        boundaryPending = true
    }

    private func separateIfNeeded(force: Bool) {
        guard force || boundaryPending, !isUndoing, !isRedoing else { return }

        alignGroups()
        guard groupingLevel > 0, !groups.contains(.caller) else { return }

        while groupingLevel > 0 {
            groups.removeLast()
            super.endUndoGrouping()
        }
        // After closing the event group by hand the manager does not open one on its own.
        // The new group stays open for the run loop, which closes exactly one at event end.
        groups.append(.system)
        super.beginUndoGrouping()
    }
}
