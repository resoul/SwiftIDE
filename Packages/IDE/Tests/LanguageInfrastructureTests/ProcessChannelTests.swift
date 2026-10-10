import Foundation
import Testing
@testable import LanguageInfrastructure

/// Compiles the production channel into an isolated probe. A missing SIGPIPE guard must fail this
/// test by killing the probe, rather than killing the whole test runner. The probe deliberately
/// restores the default disposition; a runner that ignores SIGPIPE must not mask the regression.
@Test
func aBrokenProcessPipeThrowsWithoutKillingTheClient() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pipe-probe-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = folder.appendingPathComponent("Probe.swift")
    try pipeProbe.write(to: source, atomically: true, encoding: .utf8)
    let channel = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/LanguageInfrastructure/LSPChannel.swift")
    let executable = folder.appendingPathComponent("probe")
    _ = try await BoundedProcess.run(
        executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
        arguments: ["swiftc", "-swift-version", "6", "-parse-as-library", "-module-cache-path", folder.appendingPathComponent("modules").path, channel.path, source.path, "-o", executable.path],
        timeout: .seconds(60),
        outputLimit: 1_000_000
    )
    for scenario in ["no-reader", "exited", "queued-close"] {
        let output = try await BoundedProcess.run(executable: executable, arguments: [scenario], timeout: .seconds(10), outputLimit: 10_000)

        #expect(String(decoding: output, as: UTF8.self) == "EPIPE\n", "\(scenario)")
    }
}

@Test
func aProcessChannelCarriesBytesInBothDirections() async throws {
    let channel = try ProcessChannel(executable: URL(fileURLWithPath: "/bin/cat"))
    defer { channel.close() }
    let timeout = Task { try await Task.sleep(for: .seconds(10)); channel.close() }
    defer { timeout.cancel() }
    let first = Data("first αβ😀\n".utf8), second = Data("second\n".utf8)
    try await channel.write(first)
    try await channel.write(second)
    var received = Data()
    for await data in channel.incoming {
        received.append(data)
        if received.count >= first.count + second.count { break }
    }

    #expect(received == first + second)
}

@Test
func closingAProcessChannelTwiceIsSafeAndLaterWritesAreRefused() async throws {
    let channel = try ProcessChannel(executable: URL(fileURLWithPath: "/bin/cat"))
    channel.close()
    channel.close()
    do {
        try await channel.write(Data("late".utf8))
        Issue.record("a closed channel accepted bytes")
    } catch let error as POSIXError {
        #expect(error.code == .EBADF)
    }
    for await _ in channel.incoming {}
}

private let pipeProbe = #"""
import Darwin
import Foundation

@main
struct Probe {
    static func main() async throws {
        signal(SIGPIPE, SIG_DFL)
        let scenario = CommandLine.arguments[1]
        let command: String
        switch scenario {
        case "no-reader": command = "exec 0<&-; printf closed; exec /bin/sleep 1"
        case "exited": command = "printf finished"
        default: command = "dd bs=1 count=1 of=/dev/null 2>/dev/null; printf reading; exec /bin/sleep 30"
        }
        let channel = try ProcessChannel(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", command]
        )
        defer { channel.close() }
        let writer: Task<Void, any Error>?
        if scenario == "queued-close" {
            writer = Task { try await channel.write(Data(repeating: 7, count: 2_000_000)) }
        } else {
            writer = nil
        }
        for await data in channel.incoming {
            if scenario != "exited" && !data.isEmpty { break }
        }
        do {
            if let writer {
                channel.close()
                try await writer.value
                fatalError("closing must interrupt the blocked write")
            } else {
                try await channel.write(Data("test".utf8))
            }
            fatalError("a write to a pipe with no reader must fail")
        } catch {
            let outer = error as NSError
            let error = outer.userInfo[NSUnderlyingErrorKey] as? NSError ?? outer
            guard error.domain == NSPOSIXErrorDomain && error.code == Int(EPIPE) else { throw error }
            var disposition = sigaction()
            sigaction(SIGPIPE, nil, &disposition)
            guard disposition.__sigaction_u.__sa_handler == nil else {
                fatalError("ProcessChannel changed the process-wide SIGPIPE handler")
            }
            print("EPIPE")
        }
    }
}
"""#
