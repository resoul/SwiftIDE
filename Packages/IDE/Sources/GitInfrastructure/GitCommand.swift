import Foundation
import IDEApplication

struct GitCommandResult: Sendable {
    let output: Data
    let status: Int32
    let error: String
}

/// Bounded pipe readers and process lifetime, entirely off the UI executor.
enum GitCommand {
    static func run(
        executable: URL,
        root: String,
        arguments: [String],
        input: Data? = nil,
        limit: Int = 8_000_000,
        timeout: TimeInterval = 15,
        onOutput: (@Sendable (String) -> Void)? = nil,
        network: Bool = false
    ) async throws -> GitCommandResult {
        let execution = Execution(limit: limit)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    execution.start(
                        executable: executable,
                        root: root,
                        arguments: arguments,
                        input: input,
                        timeout: timeout,
                        onOutput: onOutput,
                        network: network,
                        continuation: continuation
                    )
                }
            }
        } onCancel: { execution.cancel() }
    }

    private final class Execution: @unchecked Sendable {
        private let lock = NSLock()
        private let process = Process()
        private let limit: Int
        private var output = Data(), errors = Data()
        private var cancelled = false, expired = false, overflow = false, finished = false
        private var processGroup: Int32?
        private var streamedBytes = 0

        init(limit: Int) { self.limit = limit }

        func start(
            executable: URL,
            root: String,
            arguments: [String],
            input: Data?,
            timeout: TimeInterval,
            onOutput: (@Sendable (String) -> Void)?,
            network: Bool,
            continuation: CheckedContinuation<GitCommandResult, any Error>
        ) {
            let stdout = Pipe(), stderr = Pipe()
            var inputURL: URL?, inputHandle: FileHandle?
            defer {
                try? inputHandle?.close()
                if let inputURL { try? FileManager.default.removeItem(at: inputURL) }
            }
            process.executableURL = executable
            process.arguments = arguments
            process.currentDirectoryURL = URL(fileURLWithPath: root)
            var environment = ProcessInfo.processInfo.environment
            // Inherited Git routing must never redirect this workspace to another repository/index.
            for key in Array(environment.keys) where key.hasPrefix("GIT_") { environment[key] = nil }
            environment["GIT_TERMINAL_PROMPT"] = "0"
            environment["GIT_PAGER"] = "cat"
            environment["LC_ALL"] = "C"
            if network {
                environment["GIT_ASKPASS"] = "/usr/bin/false"
                environment["SSH_ASKPASS"] = "/usr/bin/false"
                environment["SSH_ASKPASS_REQUIRE"] = "never"
            }

            process.environment = environment
            process.standardOutput = stdout
            process.standardError = stderr
            do {
                if let input {
                    let url = FileManager.default.temporaryDirectory
                        .appendingPathComponent("swiftide-git-input-\(UUID())")
                    inputURL = url
                    try input.write(to: url)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                    inputHandle = try FileHandle(forReadingFrom: url)
                }

                process.standardInput = inputHandle ?? FileHandle.nullDevice
                try lock.withLock {
                    if cancelled { throw CancellationError() }
                    try process.run()
                    let pid = process.processIdentifier
                    if getpgid(pid) == pid { processGroup = pid }
                }
            } catch {
                continuation.resume(throwing: error is CancellationError
                    ? error
                    : GitInspectionError.unavailable("Git could not start: \(error.localizedDescription)"))

                return
            }
            let readers = DispatchGroup()
            for (pipe, isError) in [(stdout, false), (stderr, true)] {
                readers.enter()
                DispatchQueue.global(qos: .userInitiated).async { [self] in
                    defer { readers.leave() }
                    while true {
                        let data = pipe.fileHandleForReading.availableData
                        if data.isEmpty { break }
                        let terminate = lock.withLock {
                            if isError {
                                errors.append(data)
                                if errors.count > 8192 { errors.removeFirst(errors.count - 8192) }
                            } else if !overflow {
                                if output.count + data.count > limit {
                                    overflow = true
                                    output = Data()

                                    return true
                                }

                                output.append(data)
                            }

                            return false
                        }
                        if let onOutput {
                            let preview = lock.withLock { () -> Data? in
                                guard streamedBytes < 128_000 else { return nil }

                                let preview = Data(data.prefix(128_000 - streamedBytes))
                                streamedBytes += preview.count

                                return preview
                            }
                            if let preview {
                                onOutput(String(decoding: preview, as: UTF8.self))
                                if lock.withLock({ streamedBytes == 128_000 }) {
                                    onOutput("\n[Git output preview limited]\n")
                                }
                            }
                        }

                        if terminate { end() }
                    }
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self else { return }

                let running = lock.withLock {
                    if finished { return false }
                    expired = true

                    return true
                }
                if running { end() }
            }
            process.waitUntilExit()
            readers.wait()
            let value: Result<GitCommandResult, any Error> = lock.withLock {
                finished = true
                if cancelled { return .failure(CancellationError()) }
                if overflow { return .failure(GitInspectionError.failed("Git output exceeds the preview limit")) }
                if expired { return .failure(GitInspectionError.failed("Git request timed out")) }

                return .success(GitCommandResult(
                    output: output,
                    status: process.terminationStatus,
                    error: String(decoding: errors, as: UTF8.self)
                ))
            }
            continuation.resume(with: value)
        }

        func cancel() {
            lock.withLock { cancelled = true }
            end()
        }

        private func end() {
            let group = lock.withLock { processGroup }
            guard group != nil || process.isRunning else { return }

            let pid = process.processIdentifier
            if let group { kill(-group, SIGTERM) } else { process.terminate() }
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self else { return }

                let stillFinishing = lock.withLock { !finished }
                if stillFinishing, let group { kill(-group, SIGKILL) }
                else if process.isRunning { kill(pid, SIGKILL) }
            }
        }
    }
}
