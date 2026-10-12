import Foundation
import Testing
@testable import IDEApplication

@MainActor
final class HostingMemoryStore: GitHostingAccountStore {
    var values: [GitHostingAccount]

    init(_ accounts: [GitHostingAccount] = []) { values = accounts }

    func load() throws -> [GitHostingAccount] { values }

    func save(_ accounts: [GitHostingAccount]) throws { values = accounts }
}

actor HostingMemoryCredentials: GitHostingCredentials {
    var values: [UUID: String] = [:]

    func token(account: UUID) throws -> String { values[account] ?? "" }

    func save(token: String, account: UUID) { values[account] = token }

    func remove(account: UUID) { values[account] = nil }

    var count: Int { values.count }
}

actor HostingMemoryAPI: GitHostingAPI {
    let sha = String(repeating: "a", count: 40)
    private var authentication: CheckedContinuation<String, Never>?
    var waiting: Bool { authentication != nil }
    private(set) var submitted: [GitHostingCreate] = []
    var moved = false

    func moveSource() { moved = true }

    func authenticate(_ account: GitHostingAccount, token: String) async throws -> String {
        await withCheckedContinuation { authentication = $0 }
    }

    func finishAuthentication() {
        authentication?.resume(returning: "fixture")
        authentication = nil
    }

    func branchSHA(in repository: GitHostedRepository, branch: String) async throws -> String {
        moved && branch == "topic" ? String(repeating: "b", count: 40) : sha
    }

    func requests(in repository: GitHostedRepository) async throws -> GitHostingPage<GitHostingRequest> {
        .init(items: [])
    }

    private(set) var checked: [String] = []

    func checks(in repository: GitHostedRepository, sha: String) async throws -> GitHostingPage<GitHostingCheck> {
        checked.append(sha)

        return .init(items: [.init(name: "build", state: "success")])
    }

    func create(in repository: GitHostedRepository, request: GitHostingCreate) async throws -> GitHostingRequest {
        guard try await branchSHA(in: repository, branch: request.source) == request.sha else {
            throw GitInspectionError.failed("Moved source")
        }

        submitted.append(request)

        return .init(
            number: 1,
            title: request.title,
            source: request.source,
            target: request.target,
            sha: request.sha,
            url: URL(string: "https://github.com/org/repo/pull/1")!,
            draft: request.draft
        )
    }
}

actor HostingMemoryGit: GitInspecting, GitHostingRemoteReading {
    var head = String(repeating: "a", count: 40)

    func move() { head = String(repeating: "b", count: 40) }

    func snapshot(at root: String) async throws -> GitSnapshot {
        .init(
            repository: .init(root: root, gitDirectory: root + "/.git", commonDirectory: root + "/.git"),
            branch: "topic",
            head: head,
            changes: [],
            branches: [.init(reference: "refs/heads/topic", oid: head)],
            mutationToken: head,
            remotes: ["origin"]
        )
    }

    func hostingRemote(in snapshot: GitSnapshot, remote: String) async throws -> String {
        "git@github.com:org/repo.git"
    }

    func history(
        in repository: GitRepository,
        revision: String,
        offset: Int,
        count: Int
    ) async throws -> GitHistoryPage {
        .init(commits: [], hasMore: false)
    }

    func files(in repository: GitRepository, commit: GitCommit) async throws -> [GitCommitFile] { [] }

    func diff(in repository: GitRepository, comparison: GitComparison) async throws -> String { "" }
}

@MainActor
struct GitHostingWorkspaceTests {
    private func wait(_ predicate: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await predicate()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(await predicate())
    }

    @Test func cancelledAuthenticationCannotPersistALateAccountOrToken() async throws {
        let api = HostingMemoryAPI(), credentials = HostingMemoryCredentials(), store = HostingMemoryStore()
        let model = GitHostingAccounts(store: store, credentials: credentials, api: api)
        model.connect(service: .github, webURL: try #require(URL(string: "https://github.com")), token: "secret")
        try await wait { await api.waiting }
        model.cancelPending()
        await api.finishAuthentication()
        for _ in 0..<20 { await Task.yield() }
        #expect(model.accounts.isEmpty && store.values.isEmpty)
        #expect(await credentials.count == 0)
        model.connect(service: .gitlab, webURL: try #require(URL(string: "https://gitlab.com")), token: "secret")
        try await wait { await api.waiting }
        await api.finishAuthentication()
        try await wait { model.state == .ready }
        let account = try #require(model.accounts.first)
        #expect(store.values == model.accounts && account.login == "fixture")
        #expect(try await credentials.token(account: account.id) == "secret")
        model.disconnect(account)
        try await wait { model.state == .ready && model.accounts.isEmpty }
        #expect(store.values.isEmpty)
        #expect(await credentials.count == 0)
    }

    @Test func localHeadChangeInvalidatesCreationButRetainsCommitSpecificCI() async throws {
        let api = HostingMemoryAPI(), git = HostingMemoryGit()
        let account = try GitHostingAccount(
            service: .github,
            webURL: #require(URL(string: "https://github.com")),
            login: "fixture"
        )
        let accounts = GitHostingAccounts(
            store: HostingMemoryStore([account]),
            credentials: HostingMemoryCredentials(),
            api: api
        )
        let workspace = GitWorkspace(root: "/fixture", service: git)
        let model = GitHostingWorkspace(workspace: workspace, accounts: accounts)
        defer {
            model.stop()
            workspace.stop()
        }
        workspace.refresh()
        try await wait { workspace.state == .ready }
        model.select(account: account.id, remote: "origin")
        model.refresh()
        try await wait { model.state == .ready }
        let original = model.checksSHA
        #expect(model.checks.count == 1 && original == workspace.snapshot?.head)
        let request = GitHostingCreate(
            title: "Review",
            body: "Full description",
            source: "topic",
            target: "main",
            sha: original
        )
        model.review(request)
        try await wait { model.canCreate }
        #expect(await api.submitted.isEmpty)
        await git.move()
        workspace.refresh()
        try await wait { workspace.state == .ready && workspace.snapshot?.head != original }
        #expect(model.plan == nil && !model.canCreate)
        #expect(model.checksSHA == original && model.notice.contains(original))
        model.create()
        #expect(await api.submitted.isEmpty)
    }

    @Test func historyCommitCIReadsOnlyThatExactCommitAndRefusesAbbreviatedInput() async throws {
        let api = HostingMemoryAPI(), git = HostingMemoryGit()
        let account = try GitHostingAccount(
            service: .github,
            webURL: #require(URL(string: "https://github.com")),
            login: "fixture"
        )
        let accounts = GitHostingAccounts(
            store: HostingMemoryStore([account]),
            credentials: HostingMemoryCredentials(),
            api: api
        )
        let workspace = GitWorkspace(root: "/fixture", service: git)
        let model = GitHostingWorkspace(workspace: workspace, accounts: accounts)
        defer {
            model.stop()
            workspace.stop()
        }
        workspace.refresh()
        try await wait { workspace.state == .ready }
        model.select(account: account.id, remote: "origin")
        for invalid in ["abc1234", String(repeating: "g", count: 40), String(repeating: "a", count: 41)] {
            model.refresh(commit: invalid)
            #expect(model.state.explanation.contains("full hexadecimal") && model.checksSHA.isEmpty)
        }
        #expect(await api.checked.isEmpty)
        let older = String(repeating: "C", count: 40)
        model.refresh(commit: older)
        #expect(model.notice.contains(older.lowercased()) && !model.notice.contains("HEAD"))
        try await wait { model.state == .ready }
        #expect(await api.checked == [older.lowercased()])
        #expect(model.checksSHA == older.lowercased() && model.checksSHA != workspace.snapshot?.head)
        model.refresh()
        try await wait { model.state == .ready && model.checksSHA == workspace.snapshot?.head }
        #expect(await api.checked == [older.lowercased(), String(repeating: "a", count: 40)])
    }

    @Test func creationIsExplicitChecksPublishedHeadAgainAndRetainsCreatedLink() async throws {
        let api = HostingMemoryAPI(), git = HostingMemoryGit()
        let account = try GitHostingAccount(
            service: .github,
            webURL: #require(URL(string: "https://github.com")),
            login: "fixture"
        )
        let accounts = GitHostingAccounts(
            store: HostingMemoryStore([account]),
            credentials: HostingMemoryCredentials(),
            api: api
        )
        let workspace = GitWorkspace(root: "/fixture", service: git), model = GitHostingWorkspace(
            workspace: workspace,
            accounts: accounts
        )
        defer {
            model.stop()
            workspace.stop()
        }
        workspace.refresh()
        try await wait { workspace.state == .ready }
        model.select(account: account.id, remote: "origin")
        let request = GitHostingCreate(
            title: "Review",
            body: "Body",
            source: "topic",
            target: "main",
            sha: try #require(workspace.snapshot?.head)
        )
        model.review(request)
        try await wait { model.canCreate }
        model.create()
        try await wait { model.created != nil }
        #expect(await api.submitted == [request])
        #expect(model.plan == nil && model.requests.first?.url == model.created?.url)
        model.review(request)
        try await wait { model.canCreate }
        await api.moveSource()
        model.create()
        try await wait {
            if case .failed = model.state { return true }

            return false
        }
        #expect(await api.submitted.count == 1)
        model.stop()
        #expect(!model.canRead && !model.canCreate)
    }
}
