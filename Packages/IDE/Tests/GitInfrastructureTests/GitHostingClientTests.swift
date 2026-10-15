import Foundation
import HTTPInfrastructure
import IDEApplication
import Testing
@testable import GitInfrastructure

actor HostingTestCredentials: GitHostingCredentials {
    var values: [UUID: String] = [:]

    func token(account: UUID) throws -> String {
        guard let token = values[account] else { throw GitInspectionError.failed("Missing fixture token") }

        return token
    }

    func save(token: String, account: UUID) { values[account] = token }

    func remove(account: UUID) { values[account] = nil }
}

actor HostingTestTransport: GitHostingTransport {
    let handler: @Sendable (URLRequest) throws -> GitHostingHTTPResponse
    private(set) var requests: [URLRequest] = []

    init(_ handler: @escaping @Sendable (URLRequest) throws -> GitHostingHTTPResponse) { self.handler = handler }

    func send(_ request: URLRequest) throws -> GitHostingHTTPResponse {
        requests.append(request)

        return try handler(request)
    }
}

struct GitHostingClientTests {
    let sha = String(repeating: "a", count: 40)

    private func response(_ object: Any, status: Int = 200) throws -> GitHostingHTTPResponse {
        .init(status: status, data: try JSONSerialization.data(withJSONObject: object))
    }

    @Test func githubRoutesAuthenticationPaginationChecksAndCreationUseExactCommit() async throws {
        let sha = sha
        let account = try GitHostingAccount(service: .github, webURL: #require(URL(string: "https://github.com")))
        let credentials = HostingTestCredentials()
        await credentials.save(token: "fixture-secret", account: account.id)
        let transport = HostingTestTransport { request in
            #expect(request.url?.host == "api.github.com")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-secret")
            let path = request.url!.path
            let object: Any
            if path == "/user" { object = ["login": "fixture"] }
            else if path.hasSuffix("/branches/topic/name") { object = ["commit": ["sha": sha]] }
            else if path.hasSuffix("/statuses") {
                object = [["context": "build", "state": "success", "target_url": "https://ci.example/build/1"]]
            }
            else if path.hasSuffix("/check-runs") {
                object = ["check_runs": [["name": "test", "conclusion": "failure"]]]
            }
            else if path.hasSuffix("/pulls") {
                let row: [String: Any] = [
                    "number": 7,
                    "title": "Request",
                    "html_url": "https://github.com/org/repo/pull/7",
                    "head": ["ref": "topic/name", "sha": sha],
                    "base": ["ref": "main"],
                    "draft": true
                ]
                if request.httpMethod == "POST" {
                    let payload = try #require(request.httpBody)
                    let body = try #require(try JSONSerialization.jsonObject(with: payload) as? [String: Any])
                    #expect(body["head"] as? String == "topic/name" && body["draft"] as? Bool == true)
                    object = row
                } else { object = [row] }
            } else { throw GitInspectionError.failed("Unexpected test endpoint " + path) }

            return .init(
                status: request.httpMethod == "POST" ? 201 : 200,
                data: try JSONSerialization.data(withJSONObject: object)
            )
        }
        let api = GitHostingClient(credentials: credentials, transport: transport)
        #expect(try await api.authenticate(account, token: "fixture-secret") == "fixture")
        let repo = try GitHostedRepository(account: account, remoteURL: "git@github.com:org/repo.git")
        let list = try await api.requests(in: repo)
        #expect(list.items.count == 1 && list.items[0].sha == sha && list.items[0].draft)
        let checks = try await api.checks(in: repo, sha: sha)
        #expect(checks.items.map(\.state) == ["success", "failure"])
        let created = try await api.create(
            in: repo,
            request: .init(
                title: "Request",
                body: "Description",
                source: "topic/name",
                target: "main",
                sha: sha,
                draft: true
            )
        )
        #expect(created.number == 7)
        #expect(await transport.requests.contains { $0.url?.absoluteString.contains("topic%2Fname") == true })
    }

    @Test func gitlabNestedProjectPathsAndDraftMRUseGitlabHeadersAndRoutes() async throws {
        let sha = sha
        let account = try GitHostingAccount(
            service: .gitlab,
            webURL: #require(URL(string: "https://gitlab.example/team-service"))
        )
        let credentials = HostingTestCredentials()
        await credentials.save(token: "fixture-secret", account: account.id)
        let transport = HostingTestTransport { request in
            #expect(request.value(forHTTPHeaderField: "PRIVATE-TOKEN") == "fixture-secret")
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            let address = request.url!.absoluteString
            let object: Any
            if request.url!.path.hasSuffix("/user") { object = ["username": "fixture"] }
            else if address.contains("/repository/branches/") { object = ["commit": ["id": sha]] }
            else if address.contains("/statuses") { object = [["name": "job", "status": "running"]] }
            else {
                #expect(address.contains("projects/group%2Fsubgroup%2Frepo/merge_requests"))
                let row: [String: Any] = [
                    "iid": 9,
                    "title": "Draft: Review",
                    "web_url": "https://gitlab.example/team-service/group/subgroup/repo/-/merge_requests/9",
                    "source_branch": "topic",
                    "target_branch": "main",
                    "sha": sha,
                    "draft": true
                ]
                if request.httpMethod == "POST" {
                    let payload = try #require(request.httpBody)
                    let body = try #require(try JSONSerialization.jsonObject(with: payload) as? [String: Any])
                    #expect(body["title"] as? String == "Draft: Review" && body["remove_source_branch"] as? Bool ==
                        false)
                    object = row
                } else { object = [row] }
            }

            return .init(
                status: request.httpMethod == "POST" ? 201 : 200,
                data: try JSONSerialization.data(withJSONObject: object)
            )
        }
        let api = GitHostingClient(credentials: credentials, transport: transport)
        let repo = try GitHostedRepository(
            account: account,
            remoteURL: "ssh://git@gitlab.example/team-service/group/subgroup/repo.git"
        )
        #expect(try await api.authenticate(account, token: "fixture-secret") == "fixture")
        #expect(try await api.requests(in: repo).items.first?.number == 9)
        #expect(try await api.checks(in: repo, sha: sha).items.first?.state == "running")
        #expect(try await api.create(
            in: repo,
            request: .init(title: "Review", body: "Body", source: "topic", target: "main", sha: sha, draft: true)
        ).number == 9)
    }

    @Test func redirectsCredentialsMismatchedHostsAndMovedSourceCannotPublish() async throws {
        let account = try GitHostingAccount(service: .github, webURL: #require(URL(string: "https://github.com")))
        #expect(throws: GitInspectionError.self) {
            _ = try GitHostedRepository(account: account, remoteURL: "git@evil.example:org/repo.git")
        }
        #expect(throws: GitInspectionError.self) {
            _ = try GitHostedRepository(account: account, remoteURL: "https://token@github.com/org/repo.git")
        }
        #expect(throws: GitInspectionError.self) {
            _ = try GitHostingAccount(service: .gitlab, webURL: #require(URL(string: "http://gitlab.com")))
        }
        let credentials = HostingTestCredentials()
        await credentials.save(token: "fixture-secret", account: account.id)
        let redirect = HostingTestTransport { _ in .init(status: 302, data: Data("fixture-secret do not expose".utf8)) }
        let redirectAPI = GitHostingClient(credentials: credentials, transport: redirect)
        do {
            _ = try await redirectAPI.authenticate(account, token: "fixture-secret")
            Issue.record("Redirect accepted")
        }
        catch { #expect(!error.localizedDescription.contains("fixture-secret")) }
        let wrong = HostingTestTransport { _ in
            .init(
                status: 200,
                data: try JSONSerialization.data(withJSONObject: ["commit": ["sha": String(repeating: "b", count: 40)]])
            )
        }
        let repo = try GitHostedRepository(account: account, remoteURL: "https://github.com/org/repo.git")
        await #expect(throws: GitInspectionError.self) {
            _ = try await GitHostingClient(credentials: credentials, transport: wrong).create(
                in: repo,
                request: .init(
                    title: "Review",
                    body: "",
                    source: "topic",
                    target: "main",
                    sha: sha
                )
            )
        }
        #expect(await wrong.requests.allSatisfy { $0.httpMethod == "GET" })
        await #expect(throws: GitInspectionError.self) {
            _ = try await redirectAPI.authenticate(account, token: "bad\nheader")
        }
        #expect(await redirect.requests.count == 1)
    }

    @Test func hostingErrorsKeepStatusAndRetryMetadataWithoutExposingBodies() async throws {
        let account = try GitHostingAccount(service: .github, webURL: #require(URL(string: "https://github.com")))
        let credentials = HostingTestCredentials()
        for (status, kind) in [
            (401, GitHostingFailure.Kind.unauthorized),
            (403, .forbidden),
            (404, .notFound),
            (409, .conflict),
            (422, .conflict),
            (429, .rateLimited),
            (503, .serviceUnavailable)
        ] {
            let transport = HostingTestTransport { _ in
                .init(status: status, data: Data("fixture-secret".utf8), headers: ["Retry-After": "120"])
            }
            do {
                _ = try await GitHostingClient(credentials: credentials, transport: transport)
                    .authenticate(account, token: "fixture-token")
                Issue.record("HTTP failure was accepted")
            } catch let error as GitHostingFailure {
                #expect(error.kind == kind && error.statusCode == status && error.retryAfter == 120)
                #expect(!error.localizedDescription.contains("fixture-secret"))
                #expect(!error.publicationMayHaveSucceeded)
            }
            #expect(await transport.requests.count == 1)
        }
    }

    @Test func sharedTransportPreservesHostingPolicyAndNeverReplaysAnUncertainPublication() async throws {
        let account = try GitHostingAccount(service: .github, webURL: #require(URL(string: "https://github.com")))
        let credentials = HostingTestCredentials()
        await credentials.save(token: "fixture-token", account: account.id)
        let repo = try GitHostedRepository(account: account, remoteURL: "https://github.com/org/repo.git")
        let sha = sha
        for malformed in [false, true] {
            let http = HostingSharedHTTPTransport { call in
                #expect(call.policy == HTTPRequestPolicy(timeout: 30, maximumResponseBytes: 2_000_000))
                #expect(call.request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token")
                if call.request.httpMethod == "POST" {
                    if malformed { return .init(status: 201, data: Data("private malformed response".utf8)) }
                    throw HTTPError.connection(.timedOut)
                }

                return .init(status: 200, data: try JSONSerialization.data(withJSONObject: ["commit": ["sha": sha]]))
            }
            let api = GitHostingClient(
                credentials: credentials,
                transport: GitHostingURLSessionTransport(transport: http)
            )
            do {
                _ = try await api.create(in: repo, request: .init(
                    title: "Review",
                    body: "private source",
                    source: "topic",
                    target: "main",
                    sha: sha
                ))
                Issue.record("Uncertain publication succeeded")
            } catch let error as GitHostingFailure {
                #expect(error.kind == (malformed ? .invalidResponse : .timedOut))
                #expect(error.publicationMayHaveSucceeded)
                #expect(error.localizedDescription.contains("refresh before retrying"))
                #expect(!error.localizedDescription.contains("private"))
            }
            #expect(await http.calls.count == 2, "one source verification and exactly one POST")
            #expect(await http.calls.filter { $0.request.httpMethod == "POST" }.count == 1)
        }
    }

    @Test func malformedReadAndTransportCancellationRemainDistinct() async throws {
        let account = try GitHostingAccount(service: .github, webURL: #require(URL(string: "https://github.com")))
        let credentials = HostingTestCredentials()
        let malformed = HostingTestTransport { _ in .init(status: 200, data: Data("fixture-secret invalid json".utf8)) }
        await #expect(throws: GitHostingFailure(kind: .invalidResponse)) {
            try await GitHostingClient(credentials: credentials, transport: malformed)
                .authenticate(account, token: "fixture-token")
        }
        let cancelled = HostingTestTransport { _ in throw URLError(.cancelled) }
        await #expect(throws: CancellationError.self) {
            try await GitHostingClient(credentials: credentials, transport: cancelled)
                .authenticate(account, token: "fixture-token")
        }
        #expect(await cancelled.requests.count == 1)
    }

    @Test func malformedOversizedAndBoundedPaginatedResponsesAreExplicit() async throws {
        let account = try GitHostingAccount(service: .gitlab, webURL: #require(URL(string: "https://gitlab.com")))
        let credentials = HostingTestCredentials()
        await credentials.save(token: "fixture", account: account.id)
        let repo = try GitHostedRepository(account: account, remoteURL: "https://gitlab.com/group/repo.git")
        let sha = sha
        let pages = HostingTestTransport { request in
            let page = Int(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
                .first { $0.name == "page" }!.value!)!
            let values = (0..<100).map { index in
                [
                    "iid": page * 100 + index,
                    "title": "Bounded",
                    "source_branch": "topic",
                    "target_branch": "main",
                    "sha": sha,
                    "web_url": "https://gitlab.com/group/repo/-/merge_requests/\(page * 100 + index)"
                ] as [String: Any]
            }

            return .init(status: 200, data: try JSONSerialization.data(withJSONObject: values))
        }
        let list = try await GitHostingClient(credentials: credentials, transport: pages).requests(in: repo)
        #expect(list.limited && list.items.count == 500)
        #expect(await pages.requests.count == 5)
        for result in [
            GitHostingHTTPResponse(status: 200, data: Data(repeating: 0, count: 2_000_001)),
            .init(status: 200, data: Data("{}".utf8)),
            .init(
                status: 401,
                data: Data("do not expose token".utf8)
            )
        ] {
            let transport = HostingTestTransport { _ in result }
            await #expect(throws: (any Error).self) {
                _ = try await GitHostingClient(credentials: credentials, transport: transport).requests(in: repo)
            }
        }
    }
}

private actor HostingSharedHTTPTransport: HTTPTransport {
    let handler: @Sendable (HTTPRequest) throws -> HTTPResponse
    private(set) var calls: [HTTPRequest] = []

    init(_ handler: @escaping @Sendable (HTTPRequest) throws -> HTTPResponse) { self.handler = handler }

    func send(_ request: HTTPRequest) throws -> HTTPResponse {
        calls.append(request)

        return try handler(request)
    }
}
