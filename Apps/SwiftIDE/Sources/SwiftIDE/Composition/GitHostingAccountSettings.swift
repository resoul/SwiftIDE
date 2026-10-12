import Foundation
import IDEApplication

@MainActor
final class GitHostingAccountSettings: GitHostingAccountStore {
    private let defaults: UserDefaults
    private let key = "gitHostingAccounts.v1"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load() throws -> [GitHostingAccount] {
        guard let data = defaults.data(forKey: key) else { return [] }

        guard data.count <= 64_000 else { throw GitInspectionError.failed("Stored hosting metadata is oversized.") }

        return try JSONDecoder().decode([GitHostingAccount].self, from: data)
    }

    func save(_ accounts: [GitHostingAccount]) throws {
        guard accounts.count <= 16 else {
            throw GitInspectionError.failed("At most 16 hosting accounts are supported.")
        }

        for account in accounts { try account.validate() }
        let data = try JSONEncoder().encode(accounts)
        guard data.count <= 64_000 else { throw GitInspectionError.failed("Hosting metadata is oversized.") }

        defaults.set(data, forKey: key)
    }
}
