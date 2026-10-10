import Foundation
import IDEApplication
import IDEDomain

@MainActor
public final class StringDocumentBackend: DocumentEditingBackend {
    private let storage: NSMutableString

    private weak var receiver: (any NativeEditReceiver)?
    public private(set) var editGeneration: UInt64 = 0
    public private(set) var endCompositionRequests = 0
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

    public func enumerateUTF16(in range: UTF16TextRange, using body: (UnsafeBufferPointer<UInt16>) -> Void) {
        NSStringUnits.enumerate(storage, in: range, using: body)
    }

    public func commit(_ plan: PreparedDocumentEdit) {
        precondition(storage.length == plan.sourceLength)
        for edit in plan.edits {
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

    public enum Report {
        case exact
        case derived
        case claiming(NativeTextEffect)
        case unknown
        case silent
    }
    
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
