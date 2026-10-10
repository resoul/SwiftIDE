import CryptoKit
import Foundation
import IDEApplication

/// A conservative comparison of configuration inputs, without parsing every server option. Even a
/// formatting-only edit changes it. File boundaries, priority order and read failures are preserved.
enum SourceKitConfigurationFingerprint {
    static func make(user: [ConfigurationFile], project: ConfigurationFile, trust: ConfigurationTrust) -> String {
        var hash = SHA256()
        appendLength(user.count, to: &hash)
        for file in user { append(file, to: &hash) }

        // A refused file has no effect. An undecided one is included so adding a configuration to a
        // running project restarts the server, which can then ask for permission. This is not consent.
        let project = trust == .refused ? ConfigurationFile.absent : project
        if project == .absent {
            hash.update(data: Data([0]))
        } else {
            hash.update(data: Data([trust == .granted ? 1 : 2]))
            append(project, to: &hash)
        }

        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func append(_ file: ConfigurationFile, to hash: inout SHA256) {
        switch file {
        case .absent: hash.update(data: Data([0]))
        case .unreadable: hash.update(data: Data([1]))
        case .present(let data):
            hash.update(data: Data([2]))
            appendLength(data.count, to: &hash)
            hash.update(data: data)
        }
    }

    private static func appendLength(_ length: Int, to hash: inout SHA256) {
        var value = UInt64(length).bigEndian
        withUnsafeBytes(of: &value) { hash.update(bufferPointer: $0) }
    }
}
