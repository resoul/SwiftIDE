import Foundation
import IDEApplication
import IDEDomain
import IDETestSupport
import Testing
@testable import LanguageInfrastructure

// Against the real SourceKit-LSP of the selected Xcode and the SwiftPM fixture of TK-009. They
// need the tool and the fixture; without them they are not run.

private let fixture = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Fixtures/SwiftPMPackage")
private let mainFile = fixture.appendingPathComponent("Sources/App/main.swift")

private let toolAvailable: Bool = {
    guard FileManager.default.fileExists(atPath: mainFile.path) else { return false }

    let finder = Process()
    finder.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    finder.arguments = ["--find", "sourcekit-lsp"]
    finder.standardOutput = FileHandle.nullDevice
    finder.standardError = FileHandle.nullDevice

    return (try? finder.run()) != nil && { finder.waitUntilExit(); return finder.terminationStatus == 0 }()
}()

/// The channels made, so that a test can kill the server the way a crash would.
private final class Channels: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [ProcessChannel] = []
    var last: ProcessChannel? { lock.withLock { list.last } }
    var count: Int { lock.withLock { list.count } }
    func add(_ channel: ProcessChannel) { lock.withLock { list.append(channel) } }
}

@MainActor
private final class Real {
    let channels = Channels()
    let service: SourceKitLanguageService
    let session: DocumentSession
    var caret: Int

    init() throws {
        let text = try String(contentsOf: mainFile, encoding: .utf8)
        session = DocumentSession(path: mainFile.path, backend: StringDocumentBackend(loadedText: text))
        caret = (text as NSString).length
        let channels = channels
        service = SourceKitLanguageService(
            workspaceRoot: fixture,
            restartPolicy: .init(delays: [.milliseconds(100), .milliseconds(300)]),
            channelFactory: {
                let channel = try await SourceKitLanguageService.sourceKitLSP() as! ProcessChannel
                channels.add(channel)

                return channel
            }
        )
    }

    func startAndOpen() async throws {
        await service.start()
        #expect(service.state == .running)
        try await service.open(session)
    }

    func type(_ text: String) throws {
        let end = session.utf16Length
        try session.apply([DocumentEdit(range: UTF16TextRange(location: end, length: 0), replacement: text)], expectedVersion: session.version)
        caret = session.utf16Length
    }

    /// Asks for completions until the server has the project loaded and answers.
    func completionLabels(timeout: Duration = .seconds(90)) async -> [String] {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let outcome = await service.completion(for: session, caret: { self.caret })
            if case .items(let items, _) = outcome, !items.isEmpty { return items.map(\.label) }
            try? await Task.sleep(for: .milliseconds(300))
        }

        return []
    }
}

@Test(.enabled(if: toolAvailable)) @MainActor
func completionRightAfterTypingIsAboutWhatWasJustTyped() async throws {
    let real = try Real()
    try await real.startAndOpen()
    defer { Task { await real.service.stop() } }

    // Typed as fast as the main thread can: the receiver changes from a Greeter to an Int.
    try real.type("let n = 5\n")
    try real.type("greeter.")
    #expect(await real.completionLabels().contains { $0.hasPrefix("greeting") })

    try real.type("\n")
    try real.type("n.")
    let labels = await real.completionLabels()
    #expect(labels.contains("bitWidth"), "members of Int: \(labels.prefix(8))")
    #expect(!labels.contains { $0.hasPrefix("greeting") }, "not those of the Greeter typed before")
}

@Test(.enabled(if: toolAvailable)) @MainActor
func aLongRunOfSingleCharacterEditsIsFollowedExactly() async throws {
    let real = try Real()
    try await real.startAndOpen()
    defer { Task { await real.service.stop() } }

    for character in "let q: Int = 1\nq.".map(String.init) { try real.type(character) }
    for _ in 0..<150 {   // a heap of typing that the server must read in order
        try real.type(" ")
    }
    try real.type("\nq.")
    let labels = await real.completionLabels()
    #expect(labels.contains("bitWidth"), "\(labels.prefix(8))")
    #expect(real.service.sync.resyncCount == 0, "the whole run was followed edit by edit")
}

@Test(.enabled(if: toolAvailable)) @MainActor
func aKilledServerComesBackAndAnswersAboutTheCurrentText() async throws {
    let real = try Real()
    try await real.startAndOpen()
    defer { Task { await real.service.stop() } }
    #expect(await real.completionLabels().contains { $0.hasPrefix("greeting") } == false, "nothing typed yet: no member list at the end of the file")

    try real.type("let m = 7\nm.")
    #expect(await real.completionLabels().contains("bitWidth"))

    real.channels.last?.close()   // the process dies
    try real.type("\nlet z: Int = 0\nz.")   // typed while it is down
    var restarted = false
    for _ in 0..<200 {
        if real.channels.count >= 2, real.service.state == .running { restarted = true; break }
        try await Task.sleep(for: .milliseconds(100))
    }
    #expect(restarted)
    let labels = await real.completionLabels()
    #expect(labels.contains("bitWidth"), "\(labels.prefix(8))")
}

@Test(.enabled(if: toolAvailable)) @MainActor
func diagnosticsOfTheRealServerAreUnversionedSoTheyAreOnlyAsFreshAsTheLastEdit() async throws {
    let real = try Real()
    try await real.startAndOpen()
    defer { Task { await real.service.stop() } }

    try real.type("let number: Int = greeter.greeting()\n")
    var report: DiagnosticsReport?
    for _ in 0..<300 {
        if let current = real.service.diagnostics(for: real.session), current.items.contains(where: { $0.message.lowercased().contains("cannot convert") }) {
            report = current
            break
        }

        try await Task.sleep(for: .milliseconds(100))
    }
    let found = try #require(report, "no diagnostic arrived")
    // Recorded on Xcode 27.0: SourceKit-LSP sends no version even when the client says it understands one.
    #expect(found.reportedVersion == nil)
    #expect(found.freshness == .unverified)

    try real.type("// and then more\n")
    #expect(real.service.diagnostics(for: real.session)?.freshness == .stale, "the text moved on")
}
