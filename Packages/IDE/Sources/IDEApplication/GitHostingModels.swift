import Foundation

public enum GitHostingService: String, Codable, CaseIterable, Sendable { case github = "GitHub", gitlab = "GitLab" }

public struct GitHostingAccount: Codable, Equatable, Sendable {
    public let id: UUID
    public let service: GitHostingService
    public let webURL: URL
    public let apiURL: URL
    public var login: String

    public init(id: UUID = UUID(), service: GitHostingService, webURL: URL, login: String = "") throws {
        guard let components = URLComponents(url: webURL, resolvingAgainstBaseURL: false),
              components.scheme == "https", let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil, components.query == nil, components.fragment == nil,
              !components.path.contains(".."), components.path.utf8.count <= 1024 else {
            throw GitInspectionError.failed("Enter an HTTPS service address without credentials, query or fragment.")
        }

        var web = components
        web.host = host.lowercased()
        web.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !web.path.isEmpty { web.path = "/" + web.path }
        guard let normalized = web.url else { throw GitInspectionError.failed("Invalid service address.") }

        var api = web
        if service == .github, host.lowercased() == "github.com", web.path.isEmpty, web.port == nil || web.port == 443 {
            api.host = "api.github.com"
            api.path = ""
        } else { api.path += service == .github ? "/api/v3" : "/api/v4" }

        guard let apiURL = api.url else { throw GitInspectionError.failed("Invalid API address.") }

        self.id = id
        self.service = service
        self.webURL = normalized
        self.apiURL = apiURL
        self.login = login
    }

    public func validate() throws {
        let checked = try GitHostingAccount(id: id, service: service, webURL: webURL, login: login)
        guard checked == self else { throw GitInspectionError.failed("Stored account endpoints are inconsistent.") }
    }
}

public struct GitHostedRepository: Equatable, Sendable {
    public let account: GitHostingAccount
    public let path: String

    public init(account: GitHostingAccount, remoteURL: String) throws {
        try account.validate()
        let host: String, rawPath: String
        if let url = URLComponents(string: remoteURL), ["https", "ssh"].contains(url.scheme ?? ""),
           let name = url.host {
            guard url.password == nil, url.query == nil, url.fragment == nil,
                  url.scheme != "https" || (url.user == nil && (url.port ?? 443) == (account.webURL.port ?? 443)) else {
                throw GitInspectionError.failed("Remote contains credentials or uses a different HTTPS port.")
            }

            host = name.lowercased()
            rawPath = url.path
        } else {
            let value = remoteURL.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard value.count == 2, !value[0].contains("/"), !value[0].hasPrefix("-"),
                  let name = value[0].split(separator: "@", omittingEmptySubsequences: false).last else {
                throw GitInspectionError.failed("Use a matching HTTPS or SSH repository remote.")
            }

            host = String(name).lowercased()
            rawPath = String(value[1])
        }

        guard host == account.webURL.host?.lowercased(), !rawPath.contains("\\"), !rawPath.contains("\0"),
              !rawPath.contains("\n"), !rawPath.contains("\r") else {
            throw GitInspectionError.failed("Remote host does not match the selected account.")
        }

        var path = rawPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let prefix = account.webURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !prefix.isEmpty {
            guard path.hasPrefix(prefix + "/") else {
                throw GitInspectionError.failed("Remote is outside the service path.")
            }

            path = String(path.dropFirst(prefix.count + 1))
        }

        if path.hasSuffix(".git") { path.removeLast(4) }
        let pieces = path.split(separator: "/", omittingEmptySubsequences: false)
        guard pieces.count >= 2, pieces.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              path.utf8.count <= 2048, account.service != .github || pieces.count == 2 else {
            throw GitInspectionError.failed("Remote needs a valid namespace/repository path.")
        }

        self.account = account
        self.path = path
    }

    public func validateLink(_ url: URL) throws -> URL {
        guard let value = URLComponents(url: url, resolvingAgainstBaseURL: false), value.scheme == "https",
              value.host?.lowercased() == account.webURL.host?.lowercased(), value.user == nil, value.password == nil,
              (value.port ?? 443) == (account.webURL.port ?? 443) else {
            throw GitInspectionError.failed("Hosting link has an unexpected origin.")
        }

        return url
    }
}

public struct GitHostingRequest: Equatable, Sendable {
    public let number: Int
    public let title: String
    public let source: String
    public let target: String
    public let sha: String
    public let url: URL
    public let draft: Bool

    public init(number: Int, title: String, source: String, target: String, sha: String, url: URL, draft: Bool) {
        self.number = number
        self.title = title
        self.source = source
        self.target = target
        self.sha = sha
        self.url = url
        self.draft = draft
    }
}

public struct GitHostingCheck: Equatable, Sendable {
    public let name: String
    public let state: String
    public let url: URL?

    public init(name: String, state: String, url: URL? = nil) {
        self.name = name
        self.state = state
        self.url = url
    }
}

public struct GitHostingPage<Item: Sendable>: Sendable {
    public let items: [Item]
    public let limited: Bool

    public init(items: [Item], limited: Bool = false) {
        self.items = items
        self.limited = limited
    }
}

public struct GitHostingCreate: Equatable, Sendable {
    public let title: String
    public let body: String
    public let source: String
    public let target: String
    public let sha: String
    public let draft: Bool

    public init(title: String, body: String, source: String, target: String, sha: String, draft: Bool = false) {
        self.title = title
        self.body = body
        self.source = source
        self.target = target
        self.sha = sha
        self.draft = draft
    }

    public func validate() throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.utf8.count <= 256,
              body.utf8.count <= 64_000, !title.contains("\0"), !body.contains("\0"),
              !source.isEmpty, !target.isEmpty, source != target,
              source.utf8.count <= 1024, target.utf8.count <= 1024,
              !source.contains("\0"), !target.contains("\0"), !source.contains("\n"), !target.contains("\n"),
              !source.hasPrefix("-"), !target.hasPrefix("-"),
              (sha.count == 40 || sha.count == 64), sha.allSatisfy({ "0123456789abcdefABCDEF".contains($0) }) else {
            throw GitInspectionError.failed("Enter a title, distinct source/base branches and a published commit SHA.")
        }
    }
}

public protocol GitHostingCredentials: Sendable {
    func token(account: UUID) async throws -> String

    func save(token: String, account: UUID) async throws

    func remove(account: UUID) async throws
}

@MainActor public protocol GitHostingAccountStore {
    func load() throws -> [GitHostingAccount]

    func save(_ accounts: [GitHostingAccount]) throws
}

public protocol GitHostingAPI: Sendable {
    func authenticate(_ account: GitHostingAccount, token: String) async throws -> String

    func requests(in repository: GitHostedRepository) async throws -> GitHostingPage<GitHostingRequest>

    func checks(in repository: GitHostedRepository, sha: String) async throws -> GitHostingPage<GitHostingCheck>

    func branchSHA(in repository: GitHostedRepository, branch: String) async throws -> String

    func create(in repository: GitHostedRepository, request: GitHostingCreate) async throws -> GitHostingRequest
}

public protocol GitHostingRemoteReading: Sendable {
    func hostingRemote(in snapshot: GitSnapshot, remote: String) async throws -> String
}
