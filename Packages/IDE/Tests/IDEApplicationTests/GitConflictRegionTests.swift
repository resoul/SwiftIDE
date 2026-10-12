import Foundation
import IDEDomain
import IDETestSupport
import Testing
@testable import IDEApplication

@MainActor
struct GitConflictRegionTests {
    @Test func diff3RegionChoiceChangesOnlyTheSelectedRangeAndRejectsAStaleVersion() throws {
        let text = """
        prefix 👩‍💻\r\n<<<<<<< ours\r\none\r\n||||||| base\r\nold\r\n=======\r\ntwo\r\n>>>>>>> \
        theirs\r\nsuffix\r\n
        """
        let session = DocumentSession(path: "/repo/a.swift", backend: StringDocumentBackend(loadedText: text))
        let regions = GitConflictRegion.parse(text, version: session.version)
        let region = try #require(regions.first)
        #expect(region.ours == "one\r\n" && region.base == "old\r\n" && region.theirs == "two\r\n")
        try session.apply(
            [DocumentEdit(range: region.range, replacement: region.ours)],
            expectedVersion: region.version
        )
        #expect(session.snapshot().text == "prefix 👩‍💻\r\none\r\nsuffix\r\n")
        #expect(throws: DocumentError.self) {
            try session.apply(
                [DocumentEdit(range: region.range, replacement: region.theirs)],
                expectedVersion: region.version
            )
        }
    }

    @Test func missingBaseIsFilledOnlyByOneMatchingFrozenDiff3Region() throws {
        let raw = "<<<<<<< ours\none\n=======\ntwo\n>>>>>>> theirs\n"
        let ref = "<<<<<<< ours\none\n||||||| base\nold\n=======\ntwo\n>>>>>>> theirs\n"
        let region = try #require(GitConflictRegion.parse(raw, version: 4).first)
        let references = GitConflictRegion.parse(ref, version: 0)
        #expect(region.base == nil && region.addingBase(from: references).base == "old\n")
        #expect(region.addingBase(from: references + references).base == nil)
        #expect(region.addingBase(from: references).version == 4)
    }

    @Test func nestedAmbiguousMarkersAreNotAutomaticallyOfferedAsRegions() {
        let raw = "<<<<<<< ours\n<<<<<<< literal\nx\n=======\ny\n>>>>>>> theirs\n>>>>>>> outer\n"
        #expect(GitConflictRegion.parse(raw, version: 0).isEmpty)
    }
}
