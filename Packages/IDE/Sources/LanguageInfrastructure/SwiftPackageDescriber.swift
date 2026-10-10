import Foundation
import IDEApplication
import Synchronization

/// Asks SwiftPM for the targets of a package: `swift package describe --type json`.
///
/// Measured on Xcode 27.0 (ADR-031): about a second, needs no network (an unreachable dependency does
/// not matter, nothing is resolved), and with `--scratch-path` elsewhere writes nothing into the
/// project's folder. It does evaluate the package manifest, which is code of the project: the
/// language server does the same when it loads the package, so this adds no kind of action, only one
/// more process. It is bounded in time and in output, and ends with its task.
public struct SwiftPackageDescriber: PackageDescribing {
    public enum Failure: Error, Equatable, Sendable {
        case failed(String)
        case timedOut
        case outputTooLarge
    }

    public typealias Command = @Sendable (_ root: String, _ scratch: URL) -> (executable: URL, arguments: [String])

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
        self.command = command ?? { root, scratch in
            (
                URL(fileURLWithPath: "/usr/bin/xcrun"),
                ["swift", "package", "--package-path", root, "--scratch-path", scratch.path, "describe", "--type", "json"]
            )
        }
    }

    public func describe(root: String) async throws -> PackageLayout {
        let scratch = scratchDirectory.appendingPathComponent(Self.stableName(of: root), isDirectory: true)
        let (executable, arguments) = command(root, scratch)
        let run = Run(limit: outputLimit)
        let timeout = timeout
        let output: Data = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, any Error>) in
                run.start(executable: executable, arguments: arguments, timeout: timeout, continuation: continuation)
            }
        } onCancel: {
            run.cancel()
        }

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

    /// One run of the process: its output, whether it was ended for time or size, and the way out.
    private final class Run: @unchecked Sendable {
        private let lock = NSLock()
        private let limit: Int
        private let process = Process()
        private var out = Data()
        private var err = Data()
        private var timedOut = false
        private var tooLarge = false
        private var cancelled = false
        private var finished = false

        init(limit: Int) { self.limit = limit }

        func start(executable: URL, arguments: [String], timeout: Duration, continuation: CheckedContinuation<Data, any Error>) {
            let stdout = Pipe(), stderr = Pipe()
            process.executableURL = executable
            process.arguments = arguments
            process.standardOutput = stdout
            process.standardError = stderr
            process.standardInput = FileHandle.nullDevice
            stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let chunk = handle.availableData
                self?.collect(chunk)
            }
            stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let chunk = handle.availableData
                self?.lock.withLock { if let self { self.err.append(chunk); if self.err.count > 8_192 { self.err.removeFirst(self.err.count - 8_192) } } }
            }
            process.terminationHandler = { [weak self] process in
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                self?.collect(stdout.fileHandleForReading.readDataToEndOfFile())
                self?.lock.withLock { self?.err.append(stderr.fileHandleForReading.readDataToEndOfFile()) }
                self?.finish(status: process.terminationStatus, continuation: continuation)
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: Failure.failed("could not start: \(error.localizedDescription)"))

                return
            }
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                self?.endForTime()
            }
        }

        private func collect(_ chunk: Data) {
            guard !chunk.isEmpty else { return }

            let overflow: Bool = lock.withLock {
                guard !tooLarge else { return false }

                out.append(chunk)
                if out.count > limit {
                    tooLarge = true
                    out = Data()

                    return true
                }

                return false
            }
            if overflow { terminate() }
        }

        private func endForTime() {
            let running = lock.withLock { () -> Bool in
                guard !finished else { return false }

                timedOut = true

                return true
            }
            if running { terminate() }
        }

        func cancel() {
            lock.withLock { cancelled = true }
            terminate()
        }

        private func terminate() {
            guard process.isRunning else { return }

            process.terminate()
            let pid = process.processIdentifier
            // A process that ignores the polite request is not waited on for long.
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak process] in
                if let process, process.isRunning { kill(pid, SIGKILL) }
            }
        }

        private func finish(status: Int32, continuation: CheckedContinuation<Data, any Error>) {
            let (data, stderr, flags) = lock.withLock { () -> (Data, Data, (timedOut: Bool, tooLarge: Bool, cancelled: Bool)) in
                finished = true

                return (out, err, (timedOut, tooLarge, cancelled))
            }
            if flags.cancelled { return continuation.resume(throwing: CancellationError()) }

            if flags.tooLarge { return continuation.resume(throwing: Failure.outputTooLarge) }

            if flags.timedOut { return continuation.resume(throwing: Failure.timedOut) }

            guard status == 0 else {
                let said = String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)

                return continuation.resume(throwing: Failure.failed("exit \(status): \(said.suffix(600))"))
            }

            continuation.resume(returning: data)
        }
    }
}
