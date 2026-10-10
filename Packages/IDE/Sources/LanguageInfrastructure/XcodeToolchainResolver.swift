import Foundation
import IDEApplication

/// Finds the `swift` and the `sourcekit-lsp` of the selected Xcode (`xcrun --find`) and asks that
/// `swift` its version, so that the server, the package description and the context speak of the
/// same toolchain. Every question is a bounded process; any that fails leaves the toolchain unknown.
public struct XcodeToolchainResolver: ToolchainResolving {
    public typealias Ask = @Sendable (_ executable: URL, _ arguments: [String]) async throws -> String

    private let ask: Ask

    public init(ask: Ask? = nil) {
        self.ask = ask ?? { executable, arguments in
            let data = try await BoundedProcess.run(executable: executable, arguments: arguments, timeout: .seconds(10), outputLimit: 64_000)

            return String(decoding: data, as: UTF8.self)
        }
    }

    public func resolve() async -> Toolchain? {
        let xcrun = URL(fileURLWithPath: "/usr/bin/xcrun")
        do {
            let swift = try await ask(xcrun, ["--find", "swift"]).trimmingCharacters(in: .whitespacesAndNewlines)
            let server = try await ask(xcrun, ["--find", "sourcekit-lsp"]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !swift.isEmpty, !server.isEmpty else { return nil }

            // The first line names the compiler; the target line after it is the same for every run.
            let report = try await ask(URL(fileURLWithPath: swift), ["--version"])
            let version = report.split(whereSeparator: \.isNewline).first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
            guard !version.isEmpty else { return nil }

            return Toolchain(swift: swift, sourceKitLSP: server, version: version)
        } catch {
            return nil
        }
    }
}
