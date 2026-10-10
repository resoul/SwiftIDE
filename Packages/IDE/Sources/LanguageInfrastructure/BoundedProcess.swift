import Foundation

/// A process that is run to the end for its output, within a time and an output limit, and that ends
/// with the task that waits for it. Used for the tools asked about a project (`swift package
/// describe`, the toolchain's version), none of which may hang or flood the application.
public enum BoundedProcess {
    public enum Failure: Error, Equatable, Sendable {
        case failed(String)
        case timedOut
        case outputTooLarge
    }

    public static func run(executable: URL, arguments: [String], timeout: Duration, outputLimit: Int) async throws -> Data {
        let run = Run(limit: outputLimit)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, any Error>) in
                run.start(executable: executable, arguments: arguments, timeout: timeout, continuation: continuation)
            }
        } onCancel: {
            run.cancel()
        }
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
