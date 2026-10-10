import Foundation
import IDEApplication

public actor MemoryRecoveryStore: RecoveryStore {
    public enum Operation: Equatable, Sendable {
        case write(RecoveryKey, text: String)
        case remove(RecoveryKey)
    }

    private var records: [RecoveryKey: RecoveryRecord] = [:]
    private var log: [Operation] = []
    private var failingWrites = false
    private var held = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var unreadable: [String] = []

    public init() {}

    public var operations: [Operation] { log }
    public var keys: Set<RecoveryKey> { Set(records.keys) }
    public func record(for key: RecoveryKey) -> RecoveryRecord? { records[key] }
    public func setFailingWrites(_ failing: Bool) { failingWrites = failing }
    public func setUnreadable(_ descriptions: [String]) { unreadable = descriptions }

    public func hold() { held = true }

    public func release() {
        held = false
        let continuations = waiting
        waiting.removeAll()
        for continuation in continuations { continuation.resume() }
    }

    public func write(_ record: RecoveryRecord) async throws {
        if held { await withCheckedContinuation { waiting.append($0) } }
        if failingWrites { throw StoreFailure() }
        records[record.key] = record
        log.append(.write(record.key, text: record.text))
    }

    public func remove(_ key: RecoveryKey) async throws {
        records.removeValue(forKey: key)
        log.append(.remove(key))
    }

    public func pending() async throws -> RecoveryListing {
        RecoveryListing(records: records.values.sorted { $0.savedAt < $1.savedAt }, unreadable: unreadable)
    }

    public func seed(_ record: RecoveryRecord) { records[record.key] = record }

    public struct StoreFailure: Error, Equatable {}
}
