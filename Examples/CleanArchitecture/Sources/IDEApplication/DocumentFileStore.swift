import IDEDomain

/// Consumer-owned port. Production adds expected disk revision and a save receipt.
public protocol DocumentFileStore: Sendable {
    func write(_ snapshot: DocumentSnapshot) async throws
}
