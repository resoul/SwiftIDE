import Foundation
import IDEApplication
import Testing
@testable import LanguageInfrastructure

private let fixture = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Fixtures/SwiftPMPackage")

private let swiftAvailable: Bool = {
    guard FileManager.default.fileExists(atPath: fixture.appendingPathComponent("Package.swift").path) else { return false }

    let finder = Process()
    finder.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    finder.arguments = ["--find", "swift"]
    finder.standardOutput = FileHandle.nullDevice
    finder.standardError = FileHandle.nullDevice

    return (try? finder.run()) != nil && { finder.waitUntilExit(); return finder.terminationStatus == 0 }()
}()

private func scratch() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("describer-\(UUID().uuidString)", isDirectory: true)
}

private func describer(
    _ executable: String,
    _ arguments: [String],
    timeout: Duration = .seconds(5),
    limit: Int = 4_000_000
) -> SwiftPackageDescriber {
    SwiftPackageDescriber(scratchDirectory: scratch(), timeout: timeout, outputLimit: limit) { _, _ in
        (URL(fileURLWithPath: executable), arguments)
    }
}

// MARK: Against the real toolchain

@Test(.enabled(if: swiftAvailable))
func theRealSwiftDescribesTheFixtureAndLeavesTheProjectsFolderAlone() async throws {
    let root = fixture.deletingLastPathComponent().appendingPathComponent("SwiftPMPackage")
    let copy = FileManager.default.temporaryDirectory.appendingPathComponent("describe-copy-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.copyItem(at: root, to: copy)
    try? FileManager.default.removeItem(at: copy.appendingPathComponent(".build"))
    let scratchFolder = scratch()
    defer { try? FileManager.default.removeItem(at: copy); try? FileManager.default.removeItem(at: scratchFolder) }

    let layout = try await SwiftPackageDescriber(scratchDirectory: scratchFolder).describe(root: copy.path)

    #expect(layout.targets.map(\.name).sorted() == ["App", "Lib", "LibTests"])
    #expect(layout.membership(of: copy.path + "/Sources/Lib/Greeter.swift").names == ["Lib"])
    #expect(layout.membership(of: copy.path + "/Tests/LibTests/GreeterTests.swift").names == ["LibTests"])
    #expect(!FileManager.default.fileExists(atPath: copy.appendingPathComponent(".build").path), "nothing is written into the project's folder")
    #expect(FileManager.default.fileExists(atPath: scratchFolder.path), "what it needs is kept in its own folder")
}

@Test(.enabled(if: swiftAvailable))
func aFolderThatIsNotAPackageIsAFailureWithAReason() async throws {
    let empty = FileManager.default.temporaryDirectory.appendingPathComponent("not-a-package-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: empty) }

    await #expect(throws: SwiftPackageDescriber.Failure.self) {
        _ = try await SwiftPackageDescriber(scratchDirectory: scratch()).describe(root: empty.path)
    }
}

// MARK: The way the process is run

@Test
func aProcessThatDoesNotFinishInTimeIsEndedAndSaidToHaveTimedOut() async throws {
    let started = ContinuousClock.now
    await #expect(throws: SwiftPackageDescriber.Failure.timedOut) {
        _ = try await describer("/bin/sleep", ["30"], timeout: .milliseconds(300)).describe(root: "/w")
    }
    #expect(ContinuousClock.now - started < .seconds(5), "it did not wait for the process")
}

@Test
func aFailingProcessIsAFailureThatCarriesWhatItSaid() async throws {
    do {
        _ = try await describer("/bin/sh", ["-c", "echo 'manifest is broken' >&2; exit 3"]).describe(root: "/w")
        Issue.record("expected a failure")
    } catch let failure as SwiftPackageDescriber.Failure {
        guard case .failed(let reason) = failure else {
            Issue.record("wrong failure \(failure)")

            return
        }

        #expect(reason.contains("manifest is broken") && reason.contains("3"), Comment(rawValue: reason))
    }
}

@Test
func outputThatIsTooLargeEndsTheProcessAndIsRefused() async throws {
    await #expect(throws: SwiftPackageDescriber.Failure.outputTooLarge) {
        _ = try await describer("/usr/bin/yes", ["x"], limit: 10_000).describe(root: "/w")
    }
}

@Test
func outputThatIsNotDescribeJSONIsAFailureNotAGuess() async throws {
    await #expect(throws: SwiftPackageDescriber.Failure.self) {
        _ = try await describer("/bin/echo", ["hello"]).describe(root: "/w")
    }
}

@Test
func cancellingTheTaskEndsTheProcess() async throws {
    let task = Task { try await describer("/bin/sleep", ["30"], timeout: .seconds(60)).describe(root: "/w") }
    try await Task.sleep(for: .milliseconds(200))
    let started = ContinuousClock.now
    task.cancel()
    await #expect(throws: CancellationError.self) { _ = try await task.value }
    #expect(ContinuousClock.now - started < .seconds(5))
}
