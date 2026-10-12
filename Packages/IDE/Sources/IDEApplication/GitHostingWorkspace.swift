import Foundation

public struct GitHostingCreatePlan: Equatable, Sendable {
    public let repository: GitHostedRepository
    public let remote: String
    public let remoteURL: String
    public let localRepository: GitRepository
    public let source: GitBranch
    public let baseSHA: String
    public let request: GitHostingCreate
}

@MainActor
public final class GitHostingWorkspace {
    public let workspace: GitWorkspace
    public let accounts: GitHostingAccounts
    public private(set) var state = GitLoadState.idle
    public private(set) var requests: [GitHostingRequest] = []
    public private(set) var checks: [GitHostingCheck] = []
    public private(set) var checksSHA = ""
    public private(set) var reportReceivedAt: Date?
    public private(set) var reportID: UUID?
    public private(set) var reportedRepository: GitHostedRepository?
    public private(set) var checksLimited = false
    public private(set) var limited = false
    public private(set) var plan: GitHostingCreatePlan?
    public private(set) var created: GitHostingRequest?
    public private(set) var accountID: UUID?
    public private(set) var remote = ""
    public private(set) var notice = "Choose an account and repository remote, then Refresh."
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var stopped = false
    private var submitting = false
    private var workspaceSubscription: UUID?, accountSubscription: UUID?
    private var observers: [UUID: () -> Void] = [:]
    private var lastSnapshot: GitSnapshot?

    public init(workspace: GitWorkspace, accounts: GitHostingAccounts) {
        self.workspace = workspace
        self.accounts = accounts
        workspaceSubscription = workspace.subscribe { [weak self] in
            guard let self else { return }

            let current = workspace.snapshot
            if let old = lastSnapshot, let current,
               old.repository != current.repository || old.head != current.head || old.branch != current.branch
               || old.branches != current.branches || old.remotes != current.remotes {
                invalidate()
                notice = "Local repository changed. Refresh/review"
                    + (checksSHA.isEmpty ? "." : "; retained CI belongs to " + checksSHA + ".")
            }

            lastSnapshot = current
            changed()
        }
        accountSubscription = accounts.subscribe { [weak self] in
            guard let self else { return }

            if let id = accountID, !accounts.accounts.contains(where: { $0.id == id }) {
                select(account: nil, remote: remote)
            }

            changed()
        }
    }

    public var canCreate: Bool {
        !stopped && state == .ready && plan != nil && workspace.state == .ready && !workspace.operationState
            .isBusy && accounts.state != .loading
    }
    public var canRead: Bool {
        !stopped && state != .loading && workspace.state == .ready && !workspace.operationState.isBusy && accounts
            .state != .loading && selectedAccount != nil && !remote.isEmpty
    }
    private var selectedAccount: GitHostingAccount? { accounts.accounts.first { $0.id == accountID } }

    public func select(account: UUID?, remote: String) {
        accountID = account
        self.remote = remote
        requests = []
        checks = []
        checksSHA = ""
        reportReceivedAt = nil
        reportID = nil
        reportedRepository = nil
        checksLimited = false
        created = nil
        notice = "Choose an account and matching remote, then Refresh."
        invalidate()
    }

    public func invalidate() {
        let wasSubmitting = submitting
        submitting = false
        task?.cancel()
        task = nil
        generation = UUID()
        plan = nil
        state = .idle
        if wasSubmitting { notice = "Request cancelled after submission may have begun; Refresh before retrying." }
        changed()
    }

    /// Reads open requests and the CI of one exact commit: `commit` when given (history), otherwise local HEAD.
    public func refresh(commit: String? = nil) {
        guard canRead, let snapshot = workspace.snapshot, let reader = workspace.hostingRemoteReader,
              let account = selectedAccount else { return }

        let commit = commit?.lowercased()
        if let commit, !([40, 64].contains(commit.count) && commit.allSatisfy({ $0.isHexDigit && $0.isASCII })) {
            state = .failed("Enter a full hexadecimal CI commit SHA, or leave it empty for local HEAD.")
            notice = state.explanation
            changed()

            return
        }

        invalidate()
        let id = generation, remote = remote
        state = .loading
        notice = "Reading PR/MR and CI for " + (commit.map { "commit " + $0 } ?? "the exact local HEAD") + "…"
        changed()
        task = Task { [weak self, accounts] in
            do {
                let url = try await reader.hostingRemote(in: snapshot, remote: remote)
                let repository = try GitHostedRepository(account: account, remoteURL: url)
                async let entries = accounts.api.requests(in: repository)
                let report: GitHostingPage<GitHostingCheck>
                if let sha = commit ?? snapshot.head {
                    report = try await accounts.api.checks(in: repository, sha: sha)
                } else {
                    report = .init(items: [])
                }

                let list = try await entries
                guard try await reader.hostingRemote(in: snapshot, remote: remote) == url else {
                    throw GitInspectionError.failed("Remote address changed while loading.")
                }

                try Task.checkCancellation()
                guard let self, !stopped, generation == id else { return }

                requests = list.items
                checks = report.items
                checksSHA = commit ?? snapshot.head ?? ""
                reportReceivedAt = .now
                reportID = UUID()
                reportedRepository = repository
                checksLimited = report.limited
                limited = list.limited || report.limited
                notice = repository.path + " · " + account.service.rawValue
                    + (checks.isEmpty ? " · No CI checks reported for this SHA." : "")
                    + (limited ? " · Showing bounded results (up to 500 records per endpoint)." : "")
                state = .ready
                task = nil
                changed()
            } catch { self?.fail(error, generation: id) }
        }
    }

    public func review(_ request: GitHostingCreate) {
        guard canRead, let snapshot = workspace.snapshot, let reader = workspace.hostingRemoteReader,
              let account = selectedAccount,
              let source = snapshot.branches
              .first(where: { !$0.isRemote && $0.name == request.source && $0.oid == request.sha }) else {
            return
        }

        invalidate()
        let id = generation, remote = remote
        state = .loading
        changed()
        task = Task { [weak self, accounts] in
            do {
                try request.validate()
                let url = try await reader.hostingRemote(in: snapshot, remote: remote)
                let repository = try GitHostedRepository(account: account, remoteURL: url)
                guard try await accounts.api.branchSHA(in: repository, branch: request.source) == source.oid else {
                    throw GitInspectionError
                        .failed("Published source differs from local commit. Push explicitly, then review again.")
                }

                let base = try await accounts.api.branchSHA(in: repository, branch: request.target)
                guard try await reader.hostingRemote(in: snapshot, remote: remote) == url else {
                    throw GitInspectionError.failed("Remote changed during review.")
                }

                try Task.checkCancellation()
                guard let self, !stopped, generation == id, workspace.snapshot?.branches.contains(source) == true else {
                    return
                }

                plan = .init(
                    repository: repository,
                    remote: remote,
                    remoteURL: url,
                    localRepository: snapshot.repository,
                    source: source,
                    baseSHA: base,
                    request: request
                )
                state = .ready
                notice = "Reviewed " + repository.path + "\n" + source.name + " @ " + source.oid
                    + " → " + request.target + " @ " + base + "\nTitle: " + request.title
                    + "\nCreation publishes a PR/MR; no Push."
                task = nil
                changed()
            } catch { self?.fail(error, generation: id) }
        }
    }

    public func create() {
        guard canCreate, let plan, let snapshot = workspace.snapshot, let reader = workspace.hostingRemoteReader,
              snapshot.repository == plan.localRepository, snapshot.branches.contains(plan.source) else { return }

        self.plan = nil
        submitting = true
        generation = UUID()
        let id = generation
        state = .loading
        notice = "Creating PR/MR. Cancellation may leave a published request; refresh before retrying."
        changed()
        task = Task { [weak self, accounts] in
            do {
                guard try await reader.hostingRemote(in: snapshot, remote: plan.remote) == plan.remoteURL,
                      try await accounts.api.branchSHA(in: plan.repository, branch: plan.request.target) == plan
                      .baseSHA else {
                    throw GitInspectionError.failed("Remote/base branch moved; review again.")
                }

                let result = try await accounts.api.create(in: plan.repository, request: plan.request)
                try Task.checkCancellation()
                guard let self, !stopped, generation == id else { return }

                submitting = false
                created = result
                if !requests.contains(where: { $0.number == result.number }) { requests.insert(result, at: 0) }
                if requests.count > 500 {
                    requests.removeLast(requests.count - 500)
                    limited = true
                }

                notice = "Created #\(result.number): " + result.url.absoluteString
                    + (result.sha == plan.source.oid
                        ? ""
                        : "\nServer head is pending or moved; inspect the published request.")
                state = .ready
                task = nil
                changed()
            } catch { self?.fail(error, generation: id) }
        }
    }

    public func cancel() {
        let submitting = submitting
        invalidate()
        notice = submitting ? "Cancelled. A submitted PR/MR may already exist; Refresh before retrying." : "Cancelled."
        changed()
    }

    private func fail(_ error: any Error, generation id: UUID) {
        guard !stopped, generation == id else { return }

        task = nil
        plan = nil
        submitting = false
        state = .failed(error is CancellationError || Task.isCancelled
            ? "Cancelled; refresh actual hosting state before retrying."
            : error.localizedDescription)
        notice = state.explanation
        changed()
    }

    public func stop() {
        stopped = true
        invalidate()
        if let workspaceSubscription { workspace.unsubscribe(workspaceSubscription) }
        if let accountSubscription { accounts.unsubscribe(accountSubscription) }
        observers = [:]
    }

    @discardableResult public func subscribe(_ observer: @escaping () -> Void) -> UUID {
        let id = UUID()
        observers[id] = observer

        return id
    }

    public func unsubscribe(_ id: UUID) { observers[id] = nil }

    private func changed() { for callback in Array(observers.values) { callback() } }
}
