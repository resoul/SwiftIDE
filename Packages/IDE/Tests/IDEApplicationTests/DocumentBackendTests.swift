import AppKit
import EditorPlatformTextKit
import IDEApplication
import IDEDomain
import IDETestSupport
import Testing

@MainActor
private func makeBackend(textKit: Bool, text: String) -> any DocumentEditingBackend {
    if textKit { return TextKitDocumentBackend(loadedText: text) }
    return StringDocumentBackend(loadedText: text)
}

@Test(arguments: [false, true]) @MainActor
func multiEditCommitsOnceUsingOriginalUTF16Coordinates(textKit: Bool) throws {
    let document = DocumentSession(path: "Main.swift", backend: makeBackend(textKit: textKit, text: "a😀bc\r\n"))
    var changes: [DocumentChangeSet] = []
    document.subscribeToChanges { changes.append($0) }
    try document.apply([
        DocumentEdit(range: UTF16TextRange(location: 0, length: 1), replacement: "AA"),
        DocumentEdit(range: UTF16TextRange(location: 4, length: 1), replacement: "C")
    ], expectedVersion: 0)
    #expect(document.text == "AA😀bC\r\n")
    #expect(document.version == 1)
    #expect(changes.count == 1)
    #expect(changes.first?.oldVersion == 0)
    #expect(changes.first?.newVersion == 1)
    #expect(changes.first?.edits.map { $0.range.location } == [4, 0])
}

@Test(arguments: [false, true]) @MainActor
func invalidBatchLeavesTextAndVersionUnchanged(textKit: Bool) throws {
    let document = DocumentSession(path: "Main.swift", backend: makeBackend(textKit: textKit, text: "abc"))
    #expect(throws: EditValidationError.invalidRange) {
        try document.apply([
            DocumentEdit(range: UTF16TextRange(location: 0, length: 1), replacement: "X"),
            DocumentEdit(range: UTF16TextRange(location: Int.max, length: 1), replacement: "Y")
        ], expectedVersion: 0)
    }
    #expect(document.text == "abc")
    #expect(document.version == 0)
    #expect(!document.isDirty)
}

@Test(arguments: [false, true]) @MainActor
func surrogateSplitsAndAmbiguousOverlapsAreRejected(textKit: Bool) throws {
    let document = DocumentSession(path: "Main.swift", backend: makeBackend(textKit: textKit, text: "😀ab"))
    #expect(throws: EditValidationError.splitSurrogatePair) {
        try document.apply([
            DocumentEdit(range: UTF16TextRange(location: 1, length: 0), replacement: "X")
        ], expectedVersion: 0)
    }
    #expect(throws: EditValidationError.overlappingEdits) {
        try document.apply([
            DocumentEdit(range: UTF16TextRange(location: 2, length: 1), replacement: "X"),
            DocumentEdit(range: UTF16TextRange(location: 2, length: 0), replacement: "Y")
        ], expectedVersion: 0)
    }
    #expect(document.text == "😀ab")
    #expect(document.version == 0)
}

@Test(arguments: [false, true]) @MainActor
func snapshotsRemainIndependentOfLaterBackendMutations(textKit: Bool) throws {
    let document = DocumentSession(path: "Main.swift", backend: makeBackend(textKit: textKit, text: "e\u{301}\r\n😀"))
    let old = document.snapshot()
    try document.replaceText("new", expectedVersion: 0)
    #expect(Array(old.text.utf8) == Array("e\u{301}\r\n😀".utf8))
    #expect(old.version == 0)
    #expect(document.text == "new")
}

@Test @MainActor
func subscribersReceiveEachCommitAndCanUnsubscribe() throws {
    let document = DocumentSession(path: "Main.swift", backend: StringDocumentBackend(loadedText: "a"))
    var first: [UInt64] = []
    var second: [UInt64] = []
    let token = document.subscribeToChanges { first.append($0.newVersion) }
    document.subscribeToChanges { second.append($0.newVersion) }
    try document.replaceText("b", expectedVersion: 0)
    document.unsubscribeFromChanges(token)
    try document.replaceText("c", expectedVersion: 1)
    #expect(first == [1])
    #expect(second == [1, 2])
}

@Test @MainActor
func nestedEditCannotReorderPublishedChanges() throws {
    let document = DocumentSession(path: "Main.swift", backend: StringDocumentBackend(loadedText: "a"))
    var rejected = false
    document.subscribeToChanges { _ in
        do {
            try document.replaceText("nested", expectedVersion: document.version)
            Issue.record("Expected reentrantEdit")
        } catch {
            rejected = error as? DocumentError == .reentrantEdit
        }
    }
    try document.replaceText("b", expectedVersion: 0)
    #expect(rejected)
    #expect(document.text == "b")
    #expect(document.version == 1)
}

@Test @MainActor
func textKitAttributesDoNotCreateTextVersions() throws {
    let backend = TextKitDocumentBackend(loadedText: "let value = 1\n")
    let document = DocumentSession(path: "Main.swift", backend: backend)
    var events = 0
    document.subscribeToChanges { _ in events += 1 }
    try backend.setForegroundColor(.systemBlue, in: NSRange(location: 0, length: 3))
    #expect(backend.usesTextKit2)
    #expect(document.text == "let value = 1\n")
    #expect(document.version == 0)
    #expect(events == 0)
    #expect(!document.isDirty)
}
