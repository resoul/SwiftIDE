import Foundation
import IDEApplication
import IDEDomain
import IDETestSupport
import Testing
@testable import LanguageInfrastructure

private final class Servers: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var made: [ScriptedServer] = []
    func next() -> ScriptedServer {
        lock.withLock {
            let server = ScriptedServer()
            made.append(server)
            return server
        }
    }
    var count: Int { lock.withLock { made.count } }
}

@MainActor
private final class Rig {
    let servers = Servers()
    let services: LanguageServices
    let scratch: URL
    let base: URL
    let clock = ManualDelayClock()

    init() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("services-\(UUID().uuidString)", isDirectory: true).standardizedFileURL
        scratch = base.appendingPathComponent("scratch", isDirectory: true)
        let servers = servers, clock = clock
        services = LanguageServices(scratchRoot: scratch) { root, virtual in
            SourceKitLanguageService(
                workspaceRoot: root, sync: OrderedDocumentSync(virtualDirectory: virtual), clock: clock,
                channelFactory: { servers.next() }
            )
        }
    }

    /// A package folder with a source file; returns the path of the file.
    func package(_ name: String, file: String = "Sources/App/main.swift") throws -> String {
        let root = base.appendingPathComponent(name, isDirectory: true)
        let path = root.appendingPathComponent(file)
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "// package\n".write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try "let x = 1\n".write(to: path, atomically: true, encoding: .utf8)
        return path.path
    }

    func session(_ path: String, untitled: Bool = false) -> DocumentSession {
        DocumentSession(path: path, backend: StringDocumentBackend(loadedText: "let x = 1\n"), isUntitled: untitled)
    }

    func waitForServers(_ count: Int) async -> Bool {
        let servers = servers
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if servers.count >= count { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    deinit { try? FileManager.default.removeItem(at: base) }
}

// MARK: Finding the package

@Test
func theNearestPackageAboveAFileIsItsRoot() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("locator-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let outer = base.appendingPathComponent("outer"), inner = outer.appendingPathComponent("Vendor/inner")
    try FileManager.default.createDirectory(at: inner.appendingPathComponent("Sources/Lib"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outer.appendingPathComponent("Sources/App"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: base.appendingPathComponent("loose"), withIntermediateDirectories: true)
    try "x".write(to: outer.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
    try "x".write(to: inner.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)

    #expect(PackageRootLocator.root(forFile: outer.appendingPathComponent("Sources/App/main.swift").path)?.path == outer.standardizedFileURL.path)
    #expect(PackageRootLocator.root(forFile: inner.appendingPathComponent("Sources/Lib/L.swift").path)?.path == inner.standardizedFileURL.path, "the nearer package wins")
    #expect(PackageRootLocator.root(forFile: outer.appendingPathComponent("Package.swift").path)?.path == outer.standardizedFileURL.path)
    #expect(PackageRootLocator.root(forFile: base.appendingPathComponent("loose/a.swift").path) == nil)
}

// MARK: One server for each place

@Test @MainActor
func filesOfOnePackageShareAServerAndAnotherPackageGetsItsOwn() async throws {
    let rig = try Rig()
    let a1 = rig.session(try rig.package("A")), b = rig.session(try rig.package("B"))
    let a2 = rig.session(try rig.package("A", file: "Sources/App/Other.swift"))
    await rig.services.attach(a1)
    await rig.services.attach(a2)
    await rig.services.attach(b)

    #expect(rig.servers.count == 2)
    let roots = rig.servers.made.compactMap { $0.messages(named: "initialize").first?["params"]?["rootUri"]?.stringValue }
    #expect(roots.count == 2)
    #expect(roots.contains { $0.hasSuffix("/A") || $0.hasSuffix("/A/") } && roots.contains { $0.hasSuffix("/B") || $0.hasSuffix("/B/") }, "\(roots)")
    #expect(rig.services.service(for: a1) === rig.services.service(for: a2))
    #expect(rig.services.service(for: a1) !== rig.services.service(for: b))
}

@Test @MainActor
func documentsWithNoFileAndFilesOutsideAnyPackageShareTheScratchServer() async throws {
    let rig = try Rig()
    let untitled = rig.session("Untitled.swift", untitled: true)
    let loose = rig.session(rig.base.appendingPathComponent("loose/file.swift").path)
    await rig.services.attach(untitled)
    await rig.services.attach(loose)
    #expect(rig.servers.count == 1)
    #expect(rig.services.service(for: untitled) === rig.services.service(for: loose))
    let server = rig.servers.made[0]
    #expect(await server.waitUntil { server.messages(named: "textDocument/didOpen").count == 2 })
    let opened = server.messages(named: "textDocument/didOpen").compactMap { $0["params"]?["textDocument"]?["uri"]?.stringValue }
    #expect(opened.contains { $0.contains("/scratch/Untitled-") && $0.hasSuffix(".swift") }, "a made-up address inside the scratch folder: \(opened)")
    #expect(opened.contains { $0.hasSuffix("/loose/file.swift") })
}

@Test @MainActor
func aDocumentTheServerCannotUseGetsNoServer() async throws {
    let rig = try Rig()
    let notes = rig.session(rig.base.appendingPathComponent("A/notes.txt").path)
    await rig.services.attach(notes)
    #expect(rig.services.service(for: notes) == nil)
    #expect(await rig.services.completion(for: notes, caret: { 0 }) == .unavailable(.notRunning))
    // And the scratch server, which nothing was given to, is still started by the next document.
    let swift = rig.session("Untitled.swift", untitled: true)
    await rig.services.attach(swift)
    #expect(rig.servers.count == 1)
}

@Test @MainActor
func closingTheLastDocumentOfAPackageStopsItsServerButNotTheScratchOne() async throws {
    let rig = try Rig()
    let inPackage = rig.session(try rig.package("A"))
    let untitled = rig.session("Untitled.swift", untitled: true)
    await rig.services.attach(inPackage)
    await rig.services.attach(untitled)
    let packageServer = rig.servers.made[0], scratchServer = rig.servers.made[1]

    rig.services.detach(inPackage)
    #expect(await packageServer.waitForMethod("exit"), "the package server is told to shut down")
    rig.services.detach(untitled)
    try await Task.sleep(for: .milliseconds(50))
    #expect(!scratchServer.methods.contains("exit"), "the shared one stays up")
    #expect(scratchServer.methods.contains("textDocument/didClose"))
}

@Test @MainActor
func savingADocumentIntoAPackageMovesItToThatPackagesServer() async throws {
    let rig = try Rig()
    let untitled = rig.session("Untitled.swift", untitled: true)
    try untitled.replaceText("let moved = 1\n", expectedVersion: 0)
    await rig.services.attach(untitled)
    let scratchServer = rig.servers.made[0]
    #expect(await scratchServer.waitForMethod("textDocument/didOpen"))

    let target = try rig.package("A", file: "Sources/App/Moved.swift")
    let files = MemoryDocumentFileStore()
    _ = try await SaveDocumentUseCase(store: files).saveAs(document: untitled, to: target, target: .newFile, registry: DocumentRegistry())

    #expect(await rig.waitForServers(2))
    let packageServer = rig.servers.made[1]
    #expect(await packageServer.waitUntil { packageServer.model().text(URL(fileURLWithPath: target).absoluteString) == "let moved = 1\n" })
    #expect(await scratchServer.waitUntil { scratchServer.model().texts.isEmpty }, "closed on the scratch server")
    #expect(rig.services.service(for: untitled)?.sync.uri(of: untitled) == URL(fileURLWithPath: target).absoluteString)
}

// MARK: Routing

@Test @MainActor
func completionGoesToTheServerOfTheDocument() async throws {
    let rig = try Rig()
    let session = rig.session(try rig.package("A"))
    await rig.services.attach(session)
    let server = rig.servers.made[0]
    #expect(await server.waitForMethod("textDocument/didOpen"))
    let outcome = await rig.services.completion(for: session, caret: { 4 })
    #expect(outcome == .items([], isIncomplete: false))
    #expect(server.messages(named: "textDocument/completion").count == 1)
    rig.services.detach(session)
    #expect(await rig.services.completion(for: session, caret: { 4 }) == .unavailable(.notRunning))
}
