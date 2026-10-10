import Foundation
import IDEApplication

/// Asks SwiftPM for the targets of a package: `swift package describe --type json`.
///
/// Measured on Xcode 27.0 (ADR-033): about a second, needs no network (an unreachable dependency does
/// not matter, nothing is resolved), and with `--scratch-path` elsewhere writes nothing into the
/// project's folder. It does evaluate the package manifest, which is code of the project: the
/// language server does the same when it loads the package, so this adds no kind of action, only one
/// more process. It is bounded in time and in output, and ends with its task. It runs the `swift` of
/// the toolchain the context agreed on (the one the language server is of), not whichever is found.
public struct SwiftPackageDescriber: PackageDescribing {
    public typealias Failure = BoundedProcess.Failure

    /// What to run for a package: the `swift` of the toolchain when there is one.
    public typealias Command = @Sendable (_ root: String, _ scratch: URL, _ swift: String?) -> (executable: URL, arguments: [String])

    private let scratchDirectory: URL
    private let timeout: Duration
    private let outputLimit: Int
    private let command: Command

    /// `scratchDirectory` is where SwiftPM keeps what it makes for this (one folder per package root),
    /// outside the package.
    public init(
        scratchDirectory: URL,
        timeout: Duration = .seconds(20),
        outputLimit: Int = 4_000_000,
        command: Command? = nil
    ) {
        self.scratchDirectory = scratchDirectory
        self.timeout = timeout
        self.outputLimit = outputLimit
        self.command = command ?? { root, scratch, swift in
            let tail = ["package", "--package-path", root, "--scratch-path", scratch.path, "describe", "--type", "json"]
            if let swift { return (URL(fileURLWithPath: swift), tail) }

            return (URL(fileURLWithPath: "/usr/bin/xcrun"), ["swift"] + tail)
        }
    }

    public func describe(root: String, toolchain: Toolchain?) async throws -> PackageLayout {
        let scratch = scratchDirectory.appendingPathComponent(Self.stableName(of: root), isDirectory: true)
        let (executable, arguments) = command(root, scratch, toolchain?.swift)
        let output = try await BoundedProcess.run(executable: executable, arguments: arguments, timeout: timeout, outputLimit: outputLimit)

        do {
            return try PackageLayout.parse(output, root: root)
        } catch let error as PackageLayout.ParseError {
            throw Failure.failed(error.reason)
        }
    }

    /// A name for the root that is the same in every run (the language's own hash is not).
    static func stableName(of root: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in root.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }

        return String(hash, radix: 16)
    }
}
