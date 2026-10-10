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
    let languages = DocumentLanguages()
    let scratch: URL
    let base: URL
    let clock = ManualDelayClock()

    let contexts = ProjectContexts()

    init(store: (any ProjectTrustStore)? = nil) throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("services-\(UUID().uuidString)", isDirectory: true).standardizedFileURL
        scratch = base.appendingPathComponent("scratch", isDirectory: true)
        let servers = servers, clock = clock
        services = LanguageServices(scratchRoot: scratch, languages: languages, contexts: contexts, trustStore: store) { root, virtual in
            SourceKitLanguageService(
                workspaceRoot: root,
                sync: OrderedDocumentSync(virtualDirectory: virtual),
                clock: clock,
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
        let deadline = ContinuousClock.now + .seconds(60)
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

// MARK: The document's language

@Test @MainActor
func aSwiftFileChosenAsAnotherLanguageLeavesItsServerAndComesBackWithTheChoiceCleared() async throws {
    let rig = try Rig()
    let session = rig.session(try rig.package("A"))
    await rig.services.attach(session)
    let server = rig.servers.made[0]
    #expect(await server.waitForMethod("textDocument/didOpen"))
    let selector = rig.languages.selector(for: session)

    selector.setOverride(.plainText)
    #expect(await server.waitUntil { server.messages(named: "textDocument/didClose").count == 1 })
    #expect(rig.services.service(for: session) == nil)
    #expect(await rig.services.completion(for: session, caret: { 0 }) == .unavailable(.notRunning), "no answer for the old language")

    selector.setOverride(nil)
    #expect(await rig.waitForServers(2), "the package server went away with its last document and starts again")
    let again = rig.servers.made[1]
    #expect(await again.waitForMethod("textDocument/didOpen"))
    #expect(again.messages(named: "textDocument/didOpen")[0]["params"]?["textDocument"]?["languageId"]?.stringValue == "swift")
}

@Test @MainActor
func aTextFileChosenAsSwiftIsGivenToTheServerOfItsPlace() async throws {
    let rig = try Rig()
    let notes = rig.session(rig.base.appendingPathComponent("A/notes.txt").path)
    await rig.services.attach(notes)
    #expect(rig.services.service(for: notes) == nil && rig.servers.count == 0)

    rig.languages.selector(for: notes).setOverride(.swift)
    #expect(await rig.waitForServers(1))
    let server = rig.servers.made[0]
    #expect(await server.waitForMethod("textDocument/didOpen"))
    #expect(server.messages(named: "textDocument/didOpen")[0]["params"]?["textDocument"]?["languageId"]?.stringValue == "swift")
    #expect(rig.services.service(for: notes) != nil)
}

@Test @MainActor
func aCFamilyDocumentIsGivenToTheServerUnderItsOwnLanguageID() async throws {
    let rig = try Rig()
    let header = rig.session(rig.base.appendingPathComponent("A/api.h").path)
    await rig.services.attach(header)
    let selector = rig.languages.selector(for: header)
    #expect(await rig.waitForServers(1))
    let server = rig.servers.made[0]

    func openedAs(_ count: Int) async -> String? {
        guard await server.waitUntil({ server.messages(named: "textDocument/didOpen").count == count }) else { return nil }

        return server.messages(named: "textDocument/didOpen")[count - 1]["params"]?["textDocument"]?["languageId"]?.stringValue
    }
    #expect(await openedAs(1) == "c", "a .h is taken for C")
    selector.setOverride(.cpp)
    #expect(await openedAs(2) == "cpp")
    selector.setOverride(.objectiveC)
    #expect(await openedAs(3) == "objective-c")
    selector.setOverride(.objectiveCPP)
    #expect(await openedAs(4) == "objective-cpp")
    #expect(server.messages(named: "textDocument/didClose").count == 3, "each change closed the document before opening it again")
}

@Test @MainActor
func plainTextIsNotGivenToTheServerEvenWhenTheFileNameIsAHeader() async throws {
    let rig = try Rig()
    let header = rig.session(rig.base.appendingPathComponent("A/api.h").path)
    await rig.services.attach(header)
    #expect(await rig.waitForServers(1))
    let server = rig.servers.made[0]
    #expect(await server.waitForMethod("textDocument/didOpen"))

    rig.languages.selector(for: header).setOverride(.plainText)
    #expect(await server.waitUntil { server.messages(named: "textDocument/didClose").count == 1 })
    try await Task.sleep(for: .milliseconds(50))
    #expect(server.messages(named: "textDocument/didOpen").count == 1 && rig.services.service(for: header) == nil)
    #expect(rig.services.serves(.objectiveCPP) && !rig.services.serves(.plainText))
}

@Test @MainActor
func aDocumentLetGoOfIsNotMovedByALaterChoice() async throws {
    let rig = try Rig()
    let notes = rig.session(rig.base.appendingPathComponent("A/notes.txt").path)
    await rig.services.attach(notes)
    rig.services.detach(notes)
    rig.languages.selector(for: notes).setOverride(.swift)
    try await Task.sleep(for: .milliseconds(50))
    #expect(rig.services.service(for: notes) == nil && rig.servers.count == 0)
}

@Test @MainActor
func savingASwiftFileAsTextTakesItOffTheServerAndSavingItBackPutsItOnAgain() async throws {
    let rig = try Rig()
    let path = try rig.package("A")
    let session = rig.session(path)
    await rig.services.attach(session)
    let server = rig.servers.made[0]
    #expect(await server.waitForMethod("textDocument/didOpen"))
    let files = MemoryDocumentFileStore()
    let registry = DocumentRegistry()

    _ = try await SaveDocumentUseCase(store: files).saveAs(document: session, to: (path as NSString).deletingLastPathComponent + "/notes.txt", target: .newFile, registry: registry)
    #expect(await server.waitUntil { server.messages(named: "textDocument/didClose").count == 1 })
    #expect(rig.services.service(for: session) == nil)

    _ = try await SaveDocumentUseCase(store: files).saveAs(document: session, to: path, target: .newFile, registry: registry)
    #expect(await rig.waitForServers(2))
    #expect(await rig.servers.made[1].waitForMethod("textDocument/didOpen"))
}

@Test
func everyLanguageButPlainTextHasAServerID() {
    #expect(DocumentLanguage.allCases.filter { $0.languageServerID == nil } == [.plainText])
    #expect(Set(DocumentLanguage.allCases.compactMap(\.languageServerID)).count == 5)
    #expect(DocumentLanguage.objectiveCPP.languageServerID == "objective-cpp")
}

// MARK: Diagnostics, hover and definition through the services

private func report(_ uri: String, version: Int? = nil, message: String = "boom", from: Int = 4, to: Int = 5) -> JSONValue {
    var params: [String: JSONValue] = [
        "uri": .string(uri),
        "diagnostics": [["message": .string(message), "severity": 2, "range": ["start": ["line": 0, "character": .int(from)], "end": ["line": 0, "character": .int(to)]]]],
    ]
    if let version { params["version"] = .int(version) }

    return .object(params)
}

@Test @MainActor
func aReportIsPlacedInTheTextAndTheObserversAreTold() async throws {
    let rig = try Rig()
    let session = rig.session(try rig.package("A"))
    await rig.services.attach(session)
    #expect(await rig.waitForServers(1))
    let service = try #require(rig.services.service(for: session))
    #expect(await rig.servers.made[0].waitForMethod("textDocument/didOpen"))
    let uri = try #require(service.sync.uri(of: session))
    var told = 0
    let token = rig.services.subscribeToDiagnostics(for: session) { told += 1 }
    #expect(rig.services.diagnostics(for: session) == nil)

    service.received("textDocument/publishDiagnostics", report(uri), from: 1)
    #expect(rig.services.diagnostics(for: session) == DocumentDiagnostics(
        items: [DocumentDiagnostic(range: UTF16TextRange(location: 4, length: 1), severity: .warning, message: "boom")],
        version: 0,
        isVerified: false
    ), "SourceKit-LSP names no version: the report is not verified")
    #expect(told == 1)

    service.received("textDocument/publishDiagnostics", report(uri, version: 0, message: "named"), from: 1)
    #expect(rig.services.diagnostics(for: session)?.isVerified == true && rig.services.diagnostics(for: session)?.items.first?.message == "named")
    #expect(told == 2)

    rig.services.unsubscribeFromDiagnostics(token)
    service.received("textDocument/publishDiagnostics", report(uri, version: 0, message: "again"), from: 1)
    #expect(told == 2, "not told after unsubscribing")
}

@Test @MainActor
func aReportForAnOlderVersionOrForADocumentAheadOfTheServerIsNotShown() async throws {
    let rig = try Rig()
    let session = rig.session(try rig.package("A"))
    await rig.services.attach(session)
    #expect(await rig.waitForServers(1))
    let service = try #require(rig.services.service(for: session))
    #expect(await rig.servers.made[0].waitForMethod("textDocument/didOpen"))
    let uri = try #require(service.sync.uri(of: session))
    var told = 0
    rig.services.subscribeToDiagnostics(for: session) { told += 1 }

    try session.apply([DocumentEdit(range: UTF16TextRange(location: 0, length: 0), replacement: "// c\n")], expectedVersion: session.version)
    service.received("textDocument/publishDiagnostics", report(uri, version: 0), from: 1)
    #expect(rig.services.diagnostics(for: session) == nil && told == 0, "it names version 0; the text is at 1")

    service.received("textDocument/publishDiagnostics", report(uri, version: 1), from: 1)
    #expect(rig.services.diagnostics(for: session)?.version == 1 && told == 1)
}

@Test @MainActor
func aDocumentLeavingTheServerTakesItsDiagnosticsAndTellsTheObservers() async throws {
    let rig = try Rig()
    let session = rig.session(try rig.package("A"))
    await rig.services.attach(session)
    #expect(await rig.waitForServers(1))
    let service = try #require(rig.services.service(for: session))
    #expect(await rig.servers.made[0].waitForMethod("textDocument/didOpen"))
    service.received("textDocument/publishDiagnostics", report(try #require(service.sync.uri(of: session))), from: 1)
    var told = 0
    rig.services.subscribeToDiagnostics(for: session) { told += 1 }

    rig.services.detach(session)
    #expect(rig.services.diagnostics(for: session) == nil && told == 1)
}

@Test @MainActor
func hoverAndDefinitionGoToTheServerOfTheDocument() async throws {
    let rig = try Rig()
    let session = rig.session(try rig.package("A"))
    await rig.services.attach(session)
    #expect(await rig.waitForServers(1))
    #expect(await rig.servers.made[0].waitForMethod("textDocument/didOpen"))

    #expect(await rig.services.hover(for: session, offset: { 4 }) == .nothing)
    #expect(await rig.services.definition(for: session, offset: { 4 }) == .nothing)
    let server = rig.servers.made[0]
    #expect(server.messages(named: "textDocument/hover").count == 1 && server.messages(named: "textDocument/definition").count == 1)

    rig.services.detach(session)
    #expect(await rig.services.hover(for: session, offset: { 4 }) == .failed(.unavailable(.notRunning)))
    #expect(await rig.services.definition(for: session, offset: { 4 }) == .failed(.unavailable(.notRunning)))
}

// MARK: Readiness, trust (TK-018)

@Test @MainActor
func aDocumentOfAPackageHasItsServersReadinessAndAnObserverHearsOfChanges() async throws {
    let rig = try Rig()
    let a = rig.session(try rig.package("A"))
    #expect(rig.services.readiness(for: a) == nil, "no server yet")
    var heard = 0
    let id = rig.services.subscribeToReadiness(for: a) { heard += 1 }
    await rig.services.attach(a)
    #expect(await rig.waitForServers(1))
    #expect(rig.services.readiness(for: a)?.settings == .unknown)

    let before = heard
    rig.servers.made[0].notify("$/progress", ["token": "indexing.A", "value": ["kind": "begin", "title": "Indexing", "message": "1 / 2"]])
    let deadline = ContinuousClock.now + .seconds(10)
    while rig.services.readiness(for: a)?.reason == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    #expect(rig.services.readiness(for: a)?.reason == "Preparing package · 1 / 2")
    #expect(heard > before)

    rig.services.unsubscribeFromReadiness(id)
    let after = heard
    rig.servers.made[0].notify("$/progress", ["token": "indexing.A", "value": ["kind": "end"]])
    try await Task.sleep(for: .milliseconds(100))
    #expect(heard == after, "an unsubscribed observer hears nothing")
}

@Test @MainActor
func aDocumentWithNoProjectIsOnFallbackSettings() async throws {
    let rig = try Rig()
    let loose = rig.session("/nowhere/loose.swift", untitled: true)
    await rig.services.attach(loose)
    #expect(await rig.waitForServers(1))
    #expect(rig.services.readiness(for: loose)?.settings == .fallback)
    #expect(rig.services.readiness(for: loose)?.reason == "Using fallback settings")
}

@Test @MainActor
func theTrustDecisionOfADocumentsProjectIsRecordedAndTheServerStartedAgain() async throws {
    let store = MemoryProjectTrustStore()
    let rig = try Rig(store: store)
    let a = rig.session(try rig.package("A"))
    await rig.services.attach(a)
    #expect(await rig.waitForServers(1))
    #expect(rig.services.trustDecision(for: a) == nil)

    rig.services.setTrust(.granted, for: a)
    #expect(await rig.waitForServers(2), "a new server is what the new decision is passed to")
    #expect(rig.services.trustDecision(for: a) == .granted)
    #expect(store.decision(forRoot: DocumentPath.canonical(rig.services.root(for: a).path)) == .granted)
    #expect(await rig.servers.made[1].waitForMethod("textDocument/didOpen"), "the document is opened again")

    rig.services.setTrust(nil, for: a)
    #expect(rig.services.trustDecision(for: a) == nil, "revoked: the question will be asked again")
}

@Test @MainActor
func theTrustOfAFolderWithNoProjectHasNothingToDecide() async throws {
    let store = MemoryProjectTrustStore()
    let rig = try Rig(store: store)
    let loose = rig.session("/nowhere/loose.swift", untitled: true)
    await rig.services.attach(loose)
    rig.services.setTrust(.granted, for: loose)
    #expect(store.decision(forRoot: DocumentPath.canonical(rig.scratch.path)) == nil)
    #expect(rig.servers.count == 1, "nothing was restarted")
}

// MARK: Opened folders (TK-018)

private func rootUris(_ rig: Rig) -> [String] {
    rig.servers.made.compactMap { $0.messages(named: "initialize").first?["params"]?["rootUri"]?.stringValue }
}

/// The root of each server, once that many have said it: a server exists a moment before its `initialize` is read.
@MainActor
private func rootUris(_ rig: Rig, count: Int) async -> [String] {
    let deadline = ContinuousClock.now + .seconds(30)
    while ContinuousClock.now < deadline, rootUris(rig).count < count { try? await Task.sleep(for: .milliseconds(5)) }

    return rootUris(rig)
}

@Test @MainActor
func aFileInsideAnOpenedFolderGetsAServerRootedAtTheFolderNotAtANestedPackage() async throws {
    let rig = try Rig()
    let nested = try rig.package("repo/vendor/lib")
    try "x".write(to: rig.base.appendingPathComponent("repo/MODULE.bazel"), atomically: true, encoding: .utf8)
    rig.contexts.open(folder: rig.base.appendingPathComponent("repo").path)
    let session = rig.session(nested)
    await rig.services.attach(session)

    #expect(await rig.waitForServers(1))
    let roots = await rootUris(rig, count: 1)
    #expect(roots.count == 1 && roots[0].hasSuffix("/repo/"), "\(roots)")
    #expect(rig.services.root(for: session).path.hasSuffix("/repo"))
}

@Test @MainActor
func openingAFolderMovesTheDocumentsAlreadyOpenToItsServer() async throws {
    let rig = try Rig()
    let nested = try rig.package("repo/lib")
    let session = rig.session(nested)
    await rig.services.attach(session)
    #expect(await rig.waitForServers(1))
    #expect(await rootUris(rig, count: 1).first?.hasSuffix("/repo/lib/") == true)

    rig.contexts.open(folder: rig.base.appendingPathComponent("repo").path)
    #expect(await rig.waitForServers(2), "a new server at the folder")
    #expect(await rootUris(rig, count: 2).last?.hasSuffix("/repo/") == true)
    #expect(rig.services.root(for: session).path.hasSuffix("/repo"))
    #expect(await rig.servers.made[1].waitForMethod("textDocument/didOpen"), "the document is opened there")
    #expect(await rig.servers.made[0].waitForMethod("textDocument/didClose"), "and closed at the old one")
    #expect(rig.services.runningRoots.count == 1, "the old server, left with no document, is stopped")
}

@Test @MainActor
func closingTheFolderMovesTheDocumentsBackToTheirPackage() async throws {
    let rig = try Rig()
    let nested = try rig.package("repo/lib")
    let folder = rig.base.appendingPathComponent("repo").path
    rig.contexts.open(folder: folder)
    let session = rig.session(nested)
    await rig.services.attach(session)
    #expect(await rig.waitForServers(1))

    rig.contexts.close(folder: folder)
    #expect(await rig.waitForServers(2))
    #expect(await rootUris(rig, count: 2).last?.hasSuffix("/repo/lib/") == true)
}

@Test @MainActor
func anOpenedFolderWithNoProjectIsServedOnFallbackSettings() async throws {
    let rig = try Rig()
    let file = rig.base.appendingPathComponent("plain/a.swift")
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "let x = 1\n".write(to: file, atomically: true, encoding: .utf8)
    rig.contexts.open(folder: file.deletingLastPathComponent().path)
    let session = rig.session(file.path)
    await rig.services.attach(session)

    #expect(await rig.waitForServers(1))
    #expect(rig.services.readiness(for: session)?.settings == .fallback)
    #expect(await rootUris(rig, count: 1).first?.hasSuffix("/plain/") == true)
}

@Test @MainActor
func anOpenedFolderThatIsAPackageIsNotOnFallbackSettings() async throws {
    let rig = try Rig()
    let file = try rig.package("pkg")
    rig.contexts.open(folder: rig.base.appendingPathComponent("pkg").path)
    let session = rig.session(file)
    await rig.services.attach(session)

    #expect(await rig.waitForServers(1))
    #expect(rig.services.readiness(for: session)?.settings == .unknown)
}

@Test @MainActor
func aDocumentOutsideEveryOpenedFolderKeepsTheNearestPackage() async throws {
    let rig = try Rig()
    let other = try rig.package("other")
    _ = try rig.package("repo")
    rig.contexts.open(folder: rig.base.appendingPathComponent("repo").path)
    let session = rig.session(other)
    await rig.services.attach(session)

    #expect(await rig.waitForServers(1))
    #expect(await rootUris(rig, count: 1).first?.hasSuffix("/other/") == true)
}

@Test @MainActor
func anOpenedFolderWithAPackageBelowItIsNotCalledFallbackBecauseTheServerFindsThePackage() async throws {
    let rig = try Rig()
    let nested = try rig.package("repo/lib")
    rig.contexts.open(folder: rig.base.appendingPathComponent("repo").path)
    let session = rig.session(nested)
    await rig.services.attach(session)

    #expect(await rig.waitForServers(1))
    #expect(rig.services.readiness(for: session)?.settings == .unknown, "a claim of fallback settings would be false (ADR-028)")
}

// MARK: The target of a file (TK-018)

private final class FakeDescriber: PackageDescribing, @unchecked Sendable {
    private let lock = NSLock()
    private var asked: [String] = []
    var layout: @Sendable (String) -> PackageLayout? = { root in
        PackageLayout(targets: [PackageTarget(name: "App", kind: .executable, directory: root + "/Sources/App", sources: ["main.swift"])])
    }

    var calls: [String] { lock.withLock { asked } }

    func describe(root: String) async throws -> PackageLayout {
        lock.withLock { asked.append(root) }
        guard let result = layout(root) else { throw SwiftPackageDescriber.Failure.failed("no layout") }

        return result
    }
}

@MainActor
private func waitUntil(_ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(10)
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }

    return condition()
}

@Test @MainActor
func startingTheServerOfAPackageLoadsItsLayoutAndTheDocumentKnowsItsTarget() async throws {
    let rig = try Rig()
    let describer = FakeDescriber()
    rig.services.describer = describer
    let file = try rig.package("A")
    let session = rig.session(file)
    var heard = 0
    rig.services.subscribeToReadiness(for: session) { heard += 1 }
    await rig.services.attach(session)

    #expect(await waitUntil { rig.services.targetNames(for: session) == ["App"] })
    #expect(describer.calls.count == 1 && describer.calls[0].hasSuffix("/A"))
    #expect(heard > 0, "the window is told, to show the target")
}

@Test @MainActor
func aSecondDocumentOfThePackageDoesNotDescribeItAgain() async throws {
    let rig = try Rig()
    let describer = FakeDescriber()
    rig.services.describer = describer
    let first = rig.session(try rig.package("A"))
    let second = rig.session(try rig.package("A", file: "Sources/App/Other.swift"))
    await rig.services.attach(first)
    #expect(await waitUntil { rig.services.targetNames(for: first) == ["App"] })
    await rig.services.attach(second)
    try await Task.sleep(for: .milliseconds(100))

    #expect(describer.calls.count == 1)
    #expect(rig.services.targetNames(for: second) == ["App"], "an unlisted file of the target's folder belongs to it by its place")
}

@Test @MainActor
func aDescriberThatFailsLeavesTheTargetUnknownAndRecordsWhy() async throws {
    let rig = try Rig()
    let describer = FakeDescriber()
    describer.layout = { _ in nil }
    rig.services.describer = describer
    let session = rig.session(try rig.package("A"))
    await rig.services.attach(session)
    #expect(await waitUntil { describer.calls.count == 1 })
    try await Task.sleep(for: .milliseconds(100))

    #expect(rig.services.targetNames(for: session).isEmpty)
    #expect(rig.services.layoutLog.contains { $0.contains("failed") && $0.contains("no layout") }, "\(rig.services.layoutLog)")
}

@Test @MainActor
func onlyAPackageIsDescribedNotALooseFileNorAFolderOfAnotherSystem() async throws {
    let rig = try Rig()
    let describer = FakeDescriber()
    rig.services.describer = describer
    let loose = rig.session("/nowhere/loose.swift", untitled: true)
    await rig.services.attach(loose)

    let bazel = rig.base.appendingPathComponent("bz")
    try FileManager.default.createDirectory(at: bazel, withIntermediateDirectories: true)
    try "x".write(to: bazel.appendingPathComponent("MODULE.bazel"), atomically: true, encoding: .utf8)
    try "let x = 1\n".write(to: bazel.appendingPathComponent("a.swift"), atomically: true, encoding: .utf8)
    rig.contexts.open(folder: bazel.path)
    let inBazel = rig.session(bazel.appendingPathComponent("a.swift").path)
    await rig.services.attach(inBazel)

    let plain = rig.base.appendingPathComponent("plain")
    try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
    try "let x = 1\n".write(to: plain.appendingPathComponent("b.swift"), atomically: true, encoding: .utf8)
    rig.contexts.open(folder: plain.path)
    let inPlain = rig.session(plain.appendingPathComponent("b.swift").path)
    await rig.services.attach(inPlain)

    #expect(await rig.waitForServers(3))
    try await Task.sleep(for: .milliseconds(100))
    #expect(describer.calls.isEmpty, "\(describer.calls)")
}

@Test @MainActor
func anOpenedFolderThatIsAPackageIsDescribedAtTheFolder() async throws {
    let rig = try Rig()
    let describer = FakeDescriber()
    rig.services.describer = describer
    let file = try rig.package("pkg")
    rig.contexts.open(folder: rig.base.appendingPathComponent("pkg").path)
    let session = rig.session(file)
    await rig.services.attach(session)

    #expect(await waitUntil { rig.services.targetNames(for: session) == ["App"] })
    #expect(describer.calls.count == 1)
}

@Test @MainActor
func savingThePackageManifestDescribesThePackageAgain() async throws {
    let rig = try Rig()
    let describer = FakeDescriber()
    rig.services.describer = describer
    let source = try rig.package("A")
    let manifestPath = rig.base.appendingPathComponent("A/Package.swift").path
    let files = MemoryDocumentFileStore(contents: [manifestPath: "// package\n"])
    let registry = DocumentRegistry()
    let open = OpenDocumentUseCase(store: files, registry: registry) { file in
        DocumentSession(loaded: file, backend: StringDocumentBackend(loadedText: file.text))
    }
    let manifest = try await open.execute(path: manifestPath).session
    let first = rig.session(source)
    await rig.services.attach(first)
    await rig.services.attach(manifest)
    #expect(await waitUntil { describer.calls.count == 1 })

    describer.layout = { root in
        PackageLayout(targets: [PackageTarget(name: "Renamed", kind: .executable, directory: root + "/Sources/App", sources: ["main.swift"])])
    }
    try manifest.replaceText("// package, edited\n", expectedVersion: manifest.version)
    _ = try await SaveDocumentUseCase(store: files).execute(document: manifest)

    #expect(await waitUntil { describer.calls.count == 2 })
    #expect(await waitUntil { rig.services.targetNames(for: first) == ["Renamed"] }, "the target follows the manifest")
}

@Test @MainActor
func withNoDescriberNothingIsDescribed() async throws {
    let rig = try Rig()
    let session = rig.session(try rig.package("A"))
    await rig.services.attach(session)
    #expect(await rig.waitForServers(1))
    try await Task.sleep(for: .milliseconds(50))
    #expect(rig.services.targetNames(for: session).isEmpty)
}

@Test @MainActor
func aPackageClosedAndOpenedAgainKeepsItsLayoutAndIsNotDescribedAgain() async throws {
    let rig = try Rig()
    let describer = FakeDescriber()
    rig.services.describer = describer
    let file = try rig.package("A")
    let first = rig.session(file)
    await rig.services.attach(first)
    #expect(await waitUntil { rig.services.targetNames(for: first) == ["App"] })

    rig.services.detach(first)    // the package's server stops with its last document
    let again = rig.session(file)
    await rig.services.attach(again)
    #expect(await rig.waitForServers(2), "a new server")
    try await Task.sleep(for: .milliseconds(100))

    #expect(describer.calls.count == 1, "what was learnt of the package is kept")
    #expect(rig.services.targetNames(for: again) == ["App"])
}
