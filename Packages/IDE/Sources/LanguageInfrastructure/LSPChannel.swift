import Darwin
import Foundation

/// Bytes to and from a language server. The connection above it knows nothing about processes,
/// which is what lets the tests put a scripted server on the other end.
public protocol LSPChannel: Sendable {
    func write(_ data: Data) async throws
    /// Pieces of the server's output as they arrive, in any size; finishes when the server is gone.
    var incoming: AsyncStream<Data> { get }
    func close()
}

/// A language server running as a child process, spoken to over its standard streams.
public final class ProcessChannel: LSPChannel, @unchecked Sendable {
    public let incoming: AsyncStream<Data>
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private let continuation: AsyncStream<Data>.Continuation
    private let writeQueue = DispatchQueue(label: "dev.swiftide.lsp.write")
    private let tail = ErrorTail()
    private let lifecycleLock = NSLock()
    private var isClosed = false

    /// The last lines the server wrote to its standard error: where it explains why it died.
    public var standardErrorTail: [String] { tail.lines }

    public init(executable: URL, arguments: [String] = [], currentDirectory: URL? = nil, environment: [String: String]? = nil) throws {
        let (stream, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
        incoming = stream
        self.continuation = continuation
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        if let environment { process.environment = environment }
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        // A server may close stdin between checking its state and writing. Return EPIPE for this
        // descriptor without changing SIGPIPE handling for the application or its other pipes.
        guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        let tail = tail
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                continuation.finish()
            } else {
                continuation.yield(data)
            }
        }
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                tail.append(String(decoding: data, as: UTF8.self))
            }
        }
        process.terminationHandler = { _ in
            // The pipe normally ends the stream; this covers a helper that inherited it and keeps
            // it open after the server itself has gone.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { continuation.finish() }
        }
        try process.run()
    }

    public func write(_ data: Data) async throws {
        let handle = input.fileHandleForWriting
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            writeQueue.async { [self] in
                do {
                    guard !lifecycleLock.withLock({ isClosed }) else { throw POSIXError(.EBADF) }

                    try handle.write(contentsOf: data)
                    done.resume()
                } catch {
                    done.resume(throwing: error)
                }
            }
        }
    }

    public func close() {
        let firstClose = lifecycleLock.withLock {
            guard !isClosed else { return false }

            isClosed = true

            return true
        }
        guard firstClose else { return }

        // End the reader first so a blocked write can finish. Closing its descriptor on the same
        // queue as writes prevents a concurrent close/reuse of the fd while a write still uses it.
        if process.isRunning { process.terminate() }
        continuation.finish()
        let handle = input.fileHandleForWriting
        writeQueue.async { try? handle.close() }
    }
}

private final class ErrorTail: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []

    var lines: [String] { lock.withLock { stored } }

    func append(_ text: String) {
        lock.withLock {
            stored.append(contentsOf: text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init))
            if stored.count > 60 { stored.removeFirst(stored.count - 60) }
        }
    }
}
