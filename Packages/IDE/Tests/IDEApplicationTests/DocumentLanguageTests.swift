import Foundation
import IDEApplication
import IDEDomain
import IDETestSupport
import Testing

@Test
func fileNamesSayWhichLanguageTheyAre() {
    let table: [(String, DocumentLanguage, Bool)] = [
        ("/w/a.swift", .swift, false),
        ("/w/a.SWIFT", .swift, false),
        ("/w/a.c", .c, false),
        ("/w/a.h", .c, true),
        ("/w/a.cpp", .cpp, false),
        ("/w/a.cc", .cpp, false),
        ("/w/a.cxx", .cpp, false),
        ("/w/a.hpp", .cpp, false),
        ("/w/a.hh", .cpp, false),
        ("/w/a.hxx", .cpp, false),
        ("/w/a.C", .cpp, false),
        ("/w/a.m", .objectiveC, false),
        ("/w/a.mm", .objectiveCPP, false),
        ("/w/README", .plainText, false),
        ("/w/notes.txt", .plainText, false),
        ("/w/.swift", .plainText, false),
        ("/w.swift/Makefile", .plainText, false),
    ]
    for (path, language, provisional) in table {
        #expect(DocumentLanguage.guess(forPath: path) == DocumentLanguage.Guess(language: language, isProvisional: provisional), "\(path)")
    }
}

@MainActor
private func session(_ path: String, untitled: Bool = false) -> DocumentSession {
    DocumentSession(path: path, backend: StringDocumentBackend(loadedText: "x"), isUntitled: untitled)
}

@Test @MainActor
func theNameDecidesWhenNothingElseDoes() {
    #expect(DocumentLanguageSelector(session: session("/w/a.swift")).resolved == ResolvedLanguage(language: .swift, source: .fileName, revision: 1))
    #expect(DocumentLanguageSelector(session: session("/w/a.h")).resolved == ResolvedLanguage(language: .c, source: .provisionalFileName, revision: 1))
    #expect(DocumentLanguageSelector(session: session("/w/notes")).resolved == ResolvedLanguage(language: .plainText, source: .unknown, revision: 1))
}

@Test @MainActor
func theUsersChoiceBeatsTheBuildContextWhichBeatsTheName() {
    var fromContext: DocumentLanguage? = .objectiveC
    let selector = DocumentLanguageSelector(session: session("/w/a.h"), context: { _ in fromContext })
    #expect(selector.resolved.language == .objectiveC && selector.resolved.source == .projectContext)
    selector.setOverride(.cpp)
    #expect(selector.resolved.language == .cpp && selector.resolved.source == .manual)
    fromContext = nil
    selector.contextDidChange()
    #expect(selector.resolved.language == .cpp, "the choice stands")
    selector.setOverride(nil)
    #expect(selector.resolved.language == .c && selector.resolved.source == .provisionalFileName, "back to the name")
}

@Test @MainActor
func aChangeOfContextIsPassedOn() {
    var fromContext: DocumentLanguage?
    let selector = DocumentLanguageSelector(session: session("/w/a.h"), context: { _ in fromContext })
    var seen: [ResolvedLanguage] = []
    selector.subscribe { seen.append($0) }
    fromContext = .objectiveCPP
    selector.contextDidChange()
    #expect(seen.map(\.language) == [.objectiveCPP] && seen[0].revision == 2)
    selector.contextDidChange()
    #expect(seen.count == 1, "nothing changed, nothing said")
}

@Test @MainActor
func theRevisionGrowsWithTheLanguageNotWithTheSource() {
    let selector = DocumentLanguageSelector(session: session("/w/a.swift"))
    var seen: [ResolvedLanguage] = []
    selector.subscribe { seen.append($0) }
    selector.setOverride(.swift)             // the user confirms what the name said
    #expect(seen == [ResolvedLanguage(language: .swift, source: .manual, revision: 1)], "same language: same revision")
    selector.setOverride(.cpp)
    selector.setOverride(.c)
    #expect(seen.map(\.revision) == [1, 2, 3])
}

@Test @MainActor
func choosingALanguageTouchesNeitherTextNorVersionNorDirtyState() throws {
    let s = session("/w/a.swift")
    try s.apply([DocumentEdit(range: UTF16TextRange(location: 1, length: 0), replacement: "y")], expectedVersion: s.version)
    let (text, version, dirty) = (s.text, s.version, s.isDirty)
    let selector = DocumentLanguageSelector(session: s)
    selector.setOverride(.plainText)
    selector.setOverride(.objectiveCPP)
    selector.setOverride(nil)
    #expect(s.text == text && s.version == version && s.isDirty == dirty)
}

@Test @MainActor
func theChoiceIsRememberedForTheFileAndForgottenWhenClearedOrWhenTheFileIsOnlyUntitled() {
    let store = MemoryLanguageOverrideStore()
    let first = DocumentLanguageSelector(session: session("/w/a.h"), store: store)
    first.setOverride(.cpp)
    #expect(DocumentLanguageSelector(session: session("/w/a.h"), store: store).resolved.language == .cpp, "in another window, later")
    #expect(DocumentLanguageSelector(session: session("/w/b.h"), store: store).resolved.language == .c)
    first.setOverride(nil)
    #expect(DocumentLanguageSelector(session: session("/w/a.h"), store: store).resolved.language == .c)

    let untitled = DocumentLanguageSelector(session: session("Untitled.swift", untitled: true), store: store)
    untitled.setOverride(.plainText)
    #expect(store.override(forPath: "Untitled.swift") == nil, "a name that is not a file is not a key")
}

@Test @MainActor
func saveAsKeepsAChoiceAndMovesItToTheNewName() async throws {
    let store = MemoryLanguageOverrideStore()
    let files = MemoryDocumentFileStore(contents: ["/w/a.h": "int x;"])
    let registry = DocumentRegistry()
    let open = OpenDocumentUseCase(store: files, registry: registry) { DocumentSession(loaded: $0, backend: StringDocumentBackend(loadedText: $0.text)) }
    let s = try await open.execute(path: "/w/a.h").session
    let selector = DocumentLanguageSelector(session: s, store: store)
    selector.setOverride(.objectiveC)
    var seen: [ResolvedLanguage] = []
    selector.subscribe { seen.append($0) }

    _ = try await SaveDocumentUseCase(store: files).saveAs(document: s, to: "/w/b.txt", target: .newFile, registry: registry)

    #expect(selector.resolved.language == .objectiveC && selector.resolved.source == .manual, "the choice is the document's")
    #expect(seen.isEmpty, "nothing changed for anyone")
    #expect(store.override(forPath: "/w/b.txt") == .objectiveC && store.override(forPath: "/w/a.h") == nil)
}

@Test @MainActor
func saveAsWithoutAChoiceDecidesAgainByTheNewName() async throws {
    let files = MemoryDocumentFileStore(contents: ["/w/Notes.txt": "x"])
    let registry = DocumentRegistry()
    let open = OpenDocumentUseCase(store: files, registry: registry) { DocumentSession(loaded: $0, backend: StringDocumentBackend(loadedText: $0.text)) }
    let s = try await open.execute(path: "/w/Notes.txt").session
    let selector = DocumentLanguageSelector(session: s)
    var seen: [ResolvedLanguage] = []
    selector.subscribe { seen.append($0) }
    #expect(selector.resolved.language == .plainText)

    _ = try await SaveDocumentUseCase(store: files).saveAs(document: s, to: "/w/Notes.mm", target: .newFile, registry: registry)

    #expect(selector.resolved == ResolvedLanguage(language: .objectiveCPP, source: .fileName, revision: 2))
    #expect(seen.count == 1)
}

@Test @MainActor
func aNewFileThatWasUntitledKeepsTheChoiceMadeWhileItWasUntitledAndStoresItUnderItsName() async throws {
    let store = MemoryLanguageOverrideStore()
    let files = MemoryDocumentFileStore(contents: [:])
    let registry = DocumentRegistry()
    let s = session("Untitled.swift", untitled: true)
    let selector = DocumentLanguageSelector(session: s, store: store)
    selector.setOverride(.cpp)
    _ = try await SaveDocumentUseCase(store: files).saveAs(document: s, to: "/w/new.txt", target: .newFile, registry: registry)
    #expect(selector.resolved.language == .cpp)
    #expect(store.override(forPath: "/w/new.txt") == .cpp)
    #expect(store.override(forPath: "Untitled.swift") == nil)
}

@Test @MainActor
func theRegistryGivesEveryoneTheSameSelectorForADocument() {
    let languages = DocumentLanguages()
    let a = session("/w/a.swift"), b = session("/w/b.swift")
    #expect(languages.selector(for: a) === languages.selector(for: a))
    #expect(languages.selector(for: a) !== languages.selector(for: b))
    let before = languages.selector(for: a)
    languages.forget(a)
    #expect(languages.selector(for: a) !== before)
}

@Test @MainActor
func theSubtitleSaysWhatAChosenLanguageLacks() {
    func parts(_ language: DocumentLanguage, _ source: LanguageSource, colours: Bool, features: Bool) -> [String] {
        LanguageSupportNote.parts(for: ResolvedLanguage(language: language, source: source, revision: 1), hasColours: colours, hasLanguageFeatures: features)
    }
    #expect(parts(.swift, .fileName, colours: true, features: true) == ["Swift"])
    #expect(parts(.cpp, .manual, colours: false, features: false) == ["C++ (chosen)", "no syntax colours", "no code completion"])
    #expect(parts(.c, .provisionalFileName, colours: true, features: false) == ["C (guess)", "no code completion"])
    #expect(parts(.objectiveC, .fileName, colours: false, features: true) == ["Objective-C", "no syntax colours"])
    #expect(parts(.plainText, .manual, colours: false, features: false) == ["Plain Text (chosen)"], "plain text is not missing anything")
}

@Test @MainActor
func aLinkAndItsTargetShareOneChoice() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lang-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let target = dir.appendingPathComponent("api.h").path, link = dir.appendingPathComponent("link.h").path
    try "int f(void);".write(toFile: target, atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)

    let store = MemoryLanguageOverrideStore()
    DocumentLanguageSelector(session: session(link), store: store).setOverride(.cpp)
    #expect(DocumentLanguageSelector(session: session(target), store: store).resolved.language == .cpp)
    #expect(store.override(forPath: DocumentPath.canonical(target)) == .cpp, "kept under the name the registry uses")
}
