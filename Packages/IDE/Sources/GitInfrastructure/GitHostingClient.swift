import Foundation
import IDEApplication

public struct GitHostingClient: GitHostingAPI {
    private let credentials: any GitHostingCredentials
    private let transport: any GitHostingTransport

    public init(
        credentials: any GitHostingCredentials,
        transport: any GitHostingTransport = GitHostingURLSessionTransport()
    ) {
        self.credentials = credentials
        self.transport = transport
    }

    public func authenticate(_ account: GitHostingAccount, token: String) async throws -> String {
        let object = try dictionary(await send(account: account, parts: ["user"], token: token))
        let field = account.service == .github ? "login" : "username"
        guard let login = object[field] as? String, !login.isEmpty, login.utf8.count <= 256 else {
            throw GitInspectionError.failed("Hosting account response has no valid login.")
        }

        return login
    }

    public func requests(in repository: GitHostedRepository) async throws -> GitHostingPage<GitHostingRequest> {
        let parts = repositoryParts(repository) + [repository.account.service == .github ? "pulls" : "merge_requests"]
        let page = try await pages(
            repository.account,
            parts: parts,
            query: ["state": repository.account.service == .github
                ? "open"
                : "opened"]
        )

        return .init(items: try page.items.map { try request($0, repository: repository) }, limited: page.limited)
    }

    public func checks(
        in repository: GitHostedRepository,
        sha: String
    ) async throws -> GitHostingPage<GitHostingCheck> {
        try validateSHA(sha)
        let prefix = repositoryParts(repository)
        if repository.account.service == .github {
            let legacy = try await pages(repository.account, parts: prefix + ["commits", sha, "statuses"])
            let runs = try await pages(
                repository.account,
                parts: prefix + ["commits", sha, "check-runs"],
                listKey: "check_runs"
            )
            var seen: Set<String> = []
            let statuses = legacy.items.compactMap { object -> GitHostingCheck? in
                let name = bounded(object["context"] as? String ?? "Status", length: 512)
                guard seen.insert(name).inserted else { return nil }

                return .init(
                    name: name,
                    state: bounded(object["state"] as? String ?? "unknown", length: 128),
                    url: externalURL(object["target_url"] as? String)
                )
            }
            let checks = runs.items.map { object in
                GitHostingCheck(
                    name: bounded(object["name"] as? String ?? "Check", length: 512),
                    state: bounded(
                        object["conclusion"] as? String ?? object["status"] as? String ?? "unknown",
                        length: 128
                    ),
                    url: externalURL(object["details_url"] as? String ?? object["html_url"] as? String)
                )
            }

            return .init(items: statuses + checks, limited: legacy.limited || runs.limited)
        }

        let statuses = try await pages(
            repository.account,
            parts: prefix + ["repository", "commits", sha, "statuses"],
            query: ["all": "false"]
        )

        return .init(items: statuses.items.map {
            .init(
                name: bounded($0["name"] as? String ?? "Job", length: 512),
                state: bounded($0["status"] as? String ?? "unknown", length: 128),
                url: externalURL($0["target_url"] as? String)
            )
        }, limited: statuses.limited)
    }

    public func branchSHA(in repository: GitHostedRepository, branch: String) async throws -> String {
        guard !branch.isEmpty, branch.utf8.count <= 1024, !branch.contains("\0"), !branch.contains("\n") else {
            throw GitInspectionError.failed("Enter a valid branch name.")
        }

        let parts = repositoryParts(repository) + (repository.account.service == .github
            ? ["branches", branch]
            : ["repository", "branches", branch])
        let value = try dictionary(await send(account: repository.account, parts: parts))
        guard let commit = value["commit"] as? [String: Any],
              let sha = commit[repository.account.service == .github ? "sha" : "id"] as? String else {
            throw GitInspectionError.failed("Remote branch response has no commit.")
        }

        try validateSHA(sha)

        return sha
    }

    public func create(
        in repository: GitHostedRepository,
        request value: GitHostingCreate
    ) async throws -> GitHostingRequest {
        try value.validate()
        guard try await branchSHA(in: repository, branch: value.source) == value.sha else {
            throw GitInspectionError
                .failed(
                    "Published source branch moved or differs from the reviewed local commit. Push/review explicitly."
                )
        }

        let body: [String: Any]
        let endpoint: String
        if repository.account.service == .github {
            endpoint = "pulls"
            body = [
                "title": value.title,
                "body": value.body,
                "head": value.source,
                "base": value.target,
                "draft": value.draft
            ]
        } else {
            endpoint = "merge_requests"
            body = [
                "title": value.draft && !value.title.hasPrefix("Draft:") ? "Draft: " + value.title : value.title,
                "description": value.body,
                "source_branch": value.source,
                "target_branch": value.target,
                "remove_source_branch": false
            ]
        }

        try Task.checkCancellation()
        let response = try dictionary(await send(
            account: repository.account,
            parts: repositoryParts(repository) + [endpoint],
            method: "POST",
            body: body
        ))

        return try request(response, repository: repository)
    }

    private func send(
        account: GitHostingAccount,
        parts: [String],
        query: [String: String] = [:],
        method: String = "GET",
        body: [String: Any]? = nil,
        token supplied: String? = nil
    ) async throws -> Data {
        try account.validate()
        let token: String
        if let supplied { token = supplied } else { token = try await credentials.token(account: account.id) }
        guard !token.isEmpty, token.utf8.count <= 16_384,
              token.unicodeScalars.allSatisfy({ (33...126).contains($0.value) }) else {
            throw GitInspectionError
                .failed("Hosting token is empty, oversized or contains whitespace/control characters.")
        }

        var components = URLComponents(url: account.apiURL, resolvingAgainstBaseURL: false)!
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        components.percentEncodedPath += "/" + parts.map { $0.addingPercentEncoding(withAllowedCharacters: allowed)! }
            .joined(separator: "/")
        components.queryItems = query.sorted { $0.key < $1.key }.map { .init(name: $0.key, value: $0.value) }
        guard let url = components.url else { throw GitInspectionError.failed("Invalid API request address.") }

        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("SwiftIDE", forHTTPHeaderField: "User-Agent")
        if account.service == .github {
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
        } else { request.setValue(token, forHTTPHeaderField: "PRIVATE-TOKEN") }

        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        try Task.checkCancellation()
        let result: GitHostingHTTPResponse
        do { result = try await transport.send(request) }
        catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            throw GitInspectionError
                .failed("Hosting connection failed. A submitted PR/MR may already exist; refresh before retrying.")
        }
        guard result.data.count <= 2_000_000, (200...299).contains(result.status) else {
            let reason = result.status == 401
                ? "Reconnect the account."
                : result.status == 403
                    ? "Check token permissions, SSO and rate limits."
                    : result.status == 404
                        ? "Repository/branch is unavailable or inaccessible."
                        : result.status == 422 || result.status == 409
                            ? "Validation failed or a request may already exist. Refresh before retrying."
                            : "Service unavailable or unsupported response; try Refresh."
            throw GitInspectionError.failed("Hosting HTTP \(result.status). " + reason)
        }

        try Task.checkCancellation()

        return result.data
    }

    private func pages(
        _ account: GitHostingAccount,
        parts: [String],
        query: [String: String] = [:],
        listKey: String? = nil
    ) async throws -> GitHostingRawPage {
        var values: [[String: Any]] = []
        for page in 1...5 {
            var parameters = query
            parameters["per_page"] = "100"
            parameters["page"] = String(page)
            let bytes = try await send(account: account, parts: parts, query: parameters)
            let object = try JSONSerialization.jsonObject(with: bytes)
            let array: Any?
            if let listKey { array = (object as? [String: Any])?[listKey] } else { array = object }
            guard let items = array as? [[String: Any]], items.count <= 100 else {
                throw GitInspectionError.failed("Malformed or oversized hosting page.")
            }

            values.append(contentsOf: items)
            if items.count < 100 { return .init(items: values) }
        }

        return .init(items: values, limited: true)
    }

    private func request(_ object: [String: Any], repository: GitHostedRepository) throws -> GitHostingRequest {
        let github = repository.account.service == .github
        guard let number = object[github ? "number" : "iid"] as? Int, number > 0,
              let title = object["title"] as? String,
              let rawURL = object[github ? "html_url" : "web_url"] as? String, let url = URL(string: rawURL) else {
            throw GitInspectionError.failed("Malformed hosting request response.")
        }

        let head = object["head"] as? [String: Any], base = object["base"] as? [String: Any]
        let refs = object["diff_refs"] as? [String: Any]
        let sha = github
            ? head?["sha"] as? String ?? ""
            : object["sha"] as? String ?? refs?["head_sha"] as? String ?? ""
        if !sha.isEmpty { try validateSHA(sha) }

        return try .init(
            number: number,
            title: bounded(title, length: 2048),
            source: bounded(
                github
                    ? head?["ref"] as? String ?? ""
                    : object["source_branch"] as? String ?? "",
                length: 2048
            ),
            target: bounded(
                github
                    ? base?["ref"] as? String ?? ""
                    : object["target_branch"] as? String ?? "",
                length: 2048
            ),
            sha: sha,
            url: repository.validateLink(url),
            draft: object["draft"] as? Bool ?? object["work_in_progress"] as? Bool ?? false
        )
    }

    private func repositoryParts(_ repository: GitHostedRepository) -> [String] {
        repository.account.service == .github
            ? ["repos"] + repository.path.components(separatedBy: "/")
            : ["projects", repository.path]
    }

    private func dictionary(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GitInspectionError.failed("Malformed hosting response.")
        }

        return object
    }

    private func validateSHA(_ sha: String) throws {
        guard (sha.count == 40 || sha.count == 64), sha.allSatisfy({ "0123456789abcdefABCDEF".contains($0) }) else {
            throw GitInspectionError.failed("Expected a full commit SHA.")
        }
    }

    private func bounded(_ text: String, length: Int) -> String { String(text.prefix(length)) }

    private func externalURL(_ text: String?) -> URL? {
        guard let text, let url = URLComponents(string: text), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil else { return nil }

        return url.url
    }
}

private struct GitHostingRawPage {
    let items: [[String: Any]]
    var limited = false
}
