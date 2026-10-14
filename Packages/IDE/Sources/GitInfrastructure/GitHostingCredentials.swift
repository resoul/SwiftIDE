import Foundation
import LocalAuthentication
import Security
import IDEApplication

public actor GitKeychainCredentials: GitHostingCredentials {
    private let service: String

    public init(service: String = "com.swiftide.git-hosting") { self.service = service }

    private func key(_ account: UUID) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account.uuidString]
    }

    public func token(account: UUID) throws -> String {
        var query = key(account)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext] = context
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        guard status == errSecSuccess, let bytes = value as? Data,
              let token = String(data: bytes, encoding: .utf8) else {
            throw GitInspectionError.failed("Hosting token unavailable in Keychain (\(status)); reconnect the account.")
        }

        return token
    }

    public func save(token: String, account: UUID) throws {
        let query = key(account), bytes = Data(token.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData: bytes] as CFDictionary)
        if status == errSecItemNotFound {
            var added = query
            added[kSecValueData] = bytes
            added[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let result = SecItemAdd(added as CFDictionary, nil)
            guard result == errSecSuccess else {
                throw GitInspectionError.failed("Cannot save hosting token in Keychain (\(result)).")
            }
        } else if status != errSecSuccess {
            throw GitInspectionError.failed("Cannot update hosting token in Keychain (\(status)).")
        }
    }

    public func remove(account: UUID) throws {
        let status = SecItemDelete(key(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw GitInspectionError.failed("Cannot remove hosting token from Keychain (\(status)).")
        }
    }
}

extension GitCLI: GitHostingRemoteReading {
    public func hostingRemote(in snapshot: GitSnapshot, remote: String) async throws -> String {
        guard snapshot.remotes.contains(remote), !remote.hasPrefix("-"), !remote.contains("\0") else {
            throw GitInspectionError.failed("Choose a configured remote.")
        }

        let urls = try GitPorcelain.string(await run(
            ["remote", "get-url", "--all", remote],
            at: snapshot.repository.root
        ))
        .split(separator: "\n").map(String.init)
        guard urls.count == 1, let url = urls.first else {
            throw GitInspectionError.failed("Hosting needs one remote address.")
        }

        try GitCloneRequest.validateSource(url)

        return url
    }
}
