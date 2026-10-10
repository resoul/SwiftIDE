import Foundation
import IDEApplication
import IDEDomain
import IDETestSupport
import Testing
import WorkspaceUI
@testable import LanguageInfrastructure

// TK-018 against the real SourceKit-LSP of the selected Xcode: its progress and its question about
// trusting the project's configuration, as ADR-028 recorded them. They need the tool and the
// fixture; without them they are not run. The package is copied under `.build`, out of the
// repository's tracked files, with a `.sourcekit-lsp/config.json` that switches indexing off.

private let repository = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
private let fixture = repository.appendingPathComponent("Fixtures/SwiftPMPackage")

private let toolAvailable: Bool = {
    guard FileManager.default.fileExists(atPath: fixture.appendingPathComponent("Package.swift").path) else { return false }

    let finder = Process()
    finder.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    finder.arguments = ["--find", "sourcekit-lsp"]
    finder.standardOutput = FileHandle.nullDevice
    finder.standardError = FileHandle.nullDevice

    return (try? finder.run()) != nil && { finder.waitUntilExit(); return finder.terminationStatus == 0 }()
}()

@MainActor
private final class Asked {
    private(set) var count = 0
    var answer: TrustDecision
    init(_ answer: TrustDecision) { self.answer = answer }

    func prompt(_ name: String, _ root: URL) async -> TrustDecision {
        count += 1

        return answer
    }
}

@MainActor
private final class Project {
    let root: URL
    let service: SourceKitLanguageService
    let session: DocumentSession
    let store = MemoryProjectTrustStore()
    let asked: Asked
    var reasons: [String] = []
    var caret: Int

    init(answer: TrustDecision, withConfiguration: Bool = true) throws {
        asked = Asked(answer)
        root = repository.appendingPathComponent("Packages/IDE/.build/e2e-readiness-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture, to: root)
        try? FileManager.default.removeItem(at: root.appendingPathComponent(".build"))
        if withConfiguration {
            let folder = root.appendingPathComponent(".sourcekit-lsp", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try #"{"backgroundIndexing": false}"#.write(to: folder.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        }

        let file = root.appendingPathComponent("Sources/App/main.swift")
        let text = try String(contentsOf: file, encoding: .utf8) + "\ngreeter."
        session = DocumentSession(path: file.path, backend: StringDocumentBackend(loadedText: text))
        caret = (text as NSString).length
        let asked = asked
        service = SourceKitLanguageService(workspaceRoot: root)
        service.trustStore = store
        service.trustPrompt = { name, root in await asked.prompt(name, root) }
        service.onReadinessChange = { [weak self] readiness in
            if let reason = readiness.reason { self?.reasons.append(reason) }
        }
    }

    func start() async throws {
        await service.start()
        try await service.open(session)
    }

    func finish() async {
        await service.stop()
        // The server's preparation may still be writing into the copy for a moment after it is stopped.
        for _ in 0..<5 {
            try? FileManager.default.removeItem(at: root)
            if !FileManager.default.fileExists(atPath: root.path) { break }

            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    func hasMemberOfTheOtherModule(within timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if case .items(let items, _) = await service.completion(for: session, caret: { self.caret }),
               items.contains(where: { $0.label.hasPrefix("greeting") }) { return true }

            try? await Task.sleep(for: .milliseconds(500))
        }

        return false
    }
}

@Test(.enabled(if: toolAvailable)) @MainActor
func aRefusedConfigurationIsIgnoredByTheRealServerAndThePackageIsStillPrepared() async throws {
    let project = try Project(answer: .refused)
    try await project.start()

    #expect(await project.hasMemberOfTheOtherModule(within: .seconds(90)), "indexing ran although the configuration asked for none: it was ignored, the preparation was not stopped")
    #expect(project.asked.count == 1, "the server asked once")
    #expect(project.service.readiness.trust == .refused)
    #expect(project.reasons.contains("Project configuration disabled"), "\(project.reasons)")
    #expect(project.reasons.contains { $0.hasPrefix("Preparing package") || $0.hasPrefix("Reloading package") }, "progress of the real server was read: \(project.reasons)")
    #expect(project.store.decision(forRoot: DocumentPath.canonical(project.root.path)) == .refused)
    await project.finish()
}

@Test(.enabled(if: toolAvailable)) @MainActor
func aGrantedConfigurationIsUsedByTheRealServer() async throws {
    let project = try Project(answer: .granted)
    try await project.start()

    // The configuration switches indexing off, so the other module is not prepared: no member of it.
    #expect(await project.hasMemberOfTheOtherModule(within: .seconds(20)) == false, "the configuration was honoured")
    #expect(project.asked.count == 1 && project.service.readiness.trust == .granted)
    await project.finish()
}

@Test(.enabled(if: toolAvailable)) @MainActor
func aPackageWithoutConfigurationIsNeverAskedAbout() async throws {
    let project = try Project(answer: .refused, withConfiguration: false)
    try await project.start()

    #expect(await project.hasMemberOfTheOtherModule(within: .seconds(90)))
    #expect(project.asked.count == 0 && project.service.readiness.trust == .undecided)
    await project.finish()
}

@Test(.enabled(if: toolAvailable)) @MainActor
func aFileOfAPackageBelowAnOpenedFolderIsServedFromTheFolderAndStillSeesItsModules() async throws {
    let base = repository.appendingPathComponent("Packages/IDE/.build/e2e-folder-\(UUID().uuidString)", isDirectory: true)
    let repo = base.appendingPathComponent("repo", isDirectory: true)
    try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: fixture, to: repo.appendingPathComponent("pkg"))
    try? FileManager.default.removeItem(at: repo.appendingPathComponent("pkg/.build"))

    let contexts = ProjectContexts()
    contexts.open(folder: repo.path)
    let services = LanguageServices(scratchRoot: base.appendingPathComponent("scratch"), contexts: contexts)
    let file = repo.appendingPathComponent("pkg/Sources/App/main.swift")
    let text = try String(contentsOf: file, encoding: .utf8) + "\ngreeter."
    let session = DocumentSession(path: file.path, backend: StringDocumentBackend(loadedText: text))
    await services.attach(session)
    #expect(services.root(for: session).path == DocumentPath.canonical(repo.path), "the opened folder, not the nested package")

    var found = false
    let deadline = ContinuousClock.now + .seconds(90)
    while ContinuousClock.now < deadline, !found {
        if case .items(let items, _) = await services.completion(for: session, caret: { session.utf16Length }) {
            found = items.contains { $0.label.hasPrefix("greeting") }
        }

        if !found { try await Task.sleep(for: .milliseconds(500)) }
    }
    #expect(found, "the server rooted at the folder found the package below it")
    #expect(services.readiness(for: session)?.settings == .unknown, "not claimed to be fallback")
    await services.stopAll()
    // The server's preparation may still be writing into the copy for a moment after it is stopped.
    for _ in 0..<5 {
        try? FileManager.default.removeItem(at: base)
        if !FileManager.default.fileExists(atPath: base.path) { break }

        try await Task.sleep(for: .milliseconds(500))
    }
}
