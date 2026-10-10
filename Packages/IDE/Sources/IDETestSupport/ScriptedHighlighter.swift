import IDEApplication
import IDEDomain
import Foundation

public final class ScriptedHighlighter: SyntaxHighlighter, @unchecked Sendable {
    public enum Call: Equatable, Sendable {
        case reset(units: Int, version: UInt64)
        case edit(from: UInt64, to: UInt64)
        case request(window: Range<Int>, version: UInt64)
        case stop
    }

    private let lock = NSLock()
    private var handler: (@Sendable (HighlightResult) -> Void)?
    private var recorded: [Call] = []

    public init() {}

    public var calls: [Call] { lock.withLock { recorded } }
    public func clearCalls() { lock.withLock { recorded.removeAll() } }

    public func answer(_ result: HighlightResult) {
        let handler = lock.withLock { self.handler }
        handler?(result)
    }

    public func connect(onResult: @escaping @Sendable (HighlightResult) -> Void) {
        lock.withLock { handler = onResult }
    }

    public func reset(text: [[UInt16]], version: UInt64) {
        lock.withLock { recorded.append(.reset(units: text.reduce(0) { $0 + $1.count }, version: version)) }
    }

    public func edit(_ changes: DocumentChangeSet) {
        lock.withLock { recorded.append(.edit(from: changes.oldVersion, to: changes.newVersion)) }
    }

    public func requestHighlights(in window: Range<Int>, version: UInt64) {
        lock.withLock { recorded.append(.request(window: window, version: version)) }
    }

    public func stop() { lock.withLock { recorded.append(.stop) } }
}
