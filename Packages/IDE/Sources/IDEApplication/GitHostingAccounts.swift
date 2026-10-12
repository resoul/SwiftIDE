import Foundation

@MainActor
public final class GitHostingAccounts {
    public let api: any GitHostingAPI
    public let credentials: any GitHostingCredentials
    public private(set) var accounts: [GitHostingAccount] = []
    public private(set) var state = GitLoadState.idle
    private let store: any GitHostingAccountStore
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var removing = false
    private var observers: [UUID: () -> Void] = [:]

    public init(store: any GitHostingAccountStore, credentials: any GitHostingCredentials, api: any GitHostingAPI) {
        self.store = store
        self.credentials = credentials
        self.api = api
        do {
            let values = try store.load()
            guard values.count <= 16, Set(values.map(\.id)).count == values.count else {
                throw GitInspectionError
                    .failed("Stored hosting accounts exceed the limit or have duplicate identities.")
            }

            for account in values { try account.validate() }
            accounts = values
        } catch { state = .failed(error.localizedDescription) }
    }

    public func connect(service: GitHostingService, webURL: URL, token: String) {
        guard state != .loading, accounts.count < 16 else { return }

        let account: GitHostingAccount
        do { account = try .init(service: service, webURL: webURL) }
        catch {
            state = .failed(error.localizedDescription)
            changed()

            return
        }
        generation = UUID()
        let id = generation
        state = .loading
        changed()
        task = Task { [weak self, api, credentials] in
            var stored = false
            do {
                let login = try await api.authenticate(account, token: token)
                try Task.checkCancellation()
                guard let self, generation == id else { return }

                var verified = account
                verified.login = login
                try await credentials.save(token: token, account: account.id)
                stored = true
                try Task.checkCancellation()
                guard generation == id else { throw CancellationError() }

                let values = accounts + [verified]
                try store.save(values)
                accounts = values
                state = .ready
                task = nil
                changed()
            } catch {
                if stored { try? await credentials.remove(account: account.id) }
                guard let self, generation == id else { return }

                state = error is CancellationError || Task.isCancelled ? .idle : .failed(error.localizedDescription)
                task = nil
                changed()
            }
        }
    }

    public func disconnect(_ account: GitHostingAccount) {
        guard state != .loading, accounts.contains(account) else { return }

        removing = true
        generation = UUID()
        let id = generation
        state = .loading
        changed()
        task = Task { [weak self, credentials] in
            do {
                try await credentials.remove(account: account.id)
                guard let self, generation == id else { return }

                let values = accounts.filter { $0.id != account.id }
                try store.save(values)
                accounts = values
                removing = false
                state = .ready
                task = nil
                changed()
            } catch {
                guard let self, generation == id else { return }

                removing = false

                state = .failed(error.localizedDescription)
                task = nil
                changed()
            }
        }
    }

    public func cancelPending() {
        guard !removing else { return }

        task?.cancel()
        generation = UUID()
        task = nil
        state = .idle
        changed()
    }

    @discardableResult public func subscribe(_ observer: @escaping () -> Void) -> UUID {
        let id = UUID()
        observers[id] = observer

        return id
    }

    public func unsubscribe(_ id: UUID) { observers[id] = nil }

    private func changed() { for callback in Array(observers.values) { callback() } }
}
