import Foundation
import IDEApplication
import IDEDomain

/// Headless/reference adapter used by tests. Production uses TextKitDocumentBackend.
/// It can also play the role of a view that mutates its storage on its own.
@MainActor
public final class StringDocumentBackend: DocumentEditingBackend {
    private let storage: NSMutableString
    private weak var receiver: (any NativeEditReceiver)?
    public private(set) var editGeneration: UInt64 = 0
    public private(set) var endCompositionRequests = 0
    /// How many times the whole text was copied out. Editing must keep this at zero.
    public private(set) var textMaterializations = 0

    public init(loadedText: String) {
        storage = NSMutableString(string: loadedText)
    }

    public var text: String {
        textMaterializations += 1
        return String(storage)
    }

    public var utf16Length: Int { storage.length }
    public func utf16Unit(at index: Int) -> UInt16 { storage.character(at: index) }

    public func substring(in range: UTF16TextRange) -> String {
        storage.substring(with: NSRange(location: range.location, length: range.length))
    }

    public func commit(_ plan: PreparedDocumentEdit) {
        precondition(storage.length == plan.sourceLength)
        for edit in plan.edits {   // descending, so earlier positions stay valid
            storage.replaceCharacters(
                in: NSRange(location: edit.range.location, length: edit.range.length), with: edit.replacement
            )
        }
        editGeneration += 1
    }

    public func attach(nativeEditReceiver: any NativeEditReceiver) {
        receiver = nativeEditReceiver
    }

    public func endComposition() {
        endCompositionRequests += 1
    }

    // MARK: Simulated native view

    /// What the simulated view tells the session about a change.
    public enum Report {
        /// The true effect, as an editor that knew the edit in advance would give it.
        case exact
        /// The true effect, but only as "this region changed".
        case derived
        /// An effect that does not match what happened.
        case claiming(NativeTextEffect)
        case unknown
        /// Nothing is reported at all.
        case silent
    }

    /// Replaces text behind the session's back and reports it as `report` says.
    @discardableResult
    public func simulateNativeEdit(
        _ range: UTF16TextRange, with replacement: String, origin: EditOrigin = .typing,
        report: Report = .exact
    ) -> NativeEditCommit {
        storage.replaceCharacters(
            in: NSRange(location: range.location, length: range.length), with: replacement
        )
        editGeneration += 1
        let effect: NativeTextEffect
        switch report {
        case .exact, .silent: effect = .replaced(range: range, replacement: replacement, isExact: true)
        case .derived: effect = .replaced(range: range, replacement: replacement, isExact: false)
        case .claiming(let claimed): effect = claimed
        case .unknown: effect = .unknown
        }
        let commit = NativeEditCommit(origin: origin, effect: effect, generation: editGeneration)
        if case .silent = report { return commit }
        receiver?.nativeEditDidCommit(commit)
        return commit
    }

    public func reportAgain(_ commit: NativeEditCommit) {
        receiver?.nativeEditDidCommit(commit)
    }

    public func simulateComposition(_ event: CompositionEvent) {
        receiver?.compositionDidChange(event)
    }

    public var allowsNativeEdit: Bool { receiver?.allowsNativeEdit() ?? true }
}
