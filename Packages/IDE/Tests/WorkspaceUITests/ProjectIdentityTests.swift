import Testing
@testable import WorkspaceUI

@Suite struct ProjectIdentityTests {
    @Test func monogramTakesFirstLetterOfFirstAndLastWords() {
        #expect(ProjectIdentity.monogram(for: "SwiftIDE") == "SI")
        #expect(ProjectIdentity.monogram(for: "em-admin") == "EA")
        #expect(ProjectIdentity.monogram(for: "em-api") == "EA")
        #expect(ProjectIdentity.monogram(for: "em-smtp-data") == "ED")
        #expect(ProjectIdentity.monogram(for: "IDEApp") == "IA")
        #expect(ProjectIdentity.monogram(for: "my_cool app") == "MA")
        #expect(ProjectIdentity.monogram(for: "preview") == "P")
        #expect(ProjectIdentity.monogram(for: " -- ").isEmpty)
    }

    @Test func accentIsStableForAProjectNameAndAlwaysFromThePalette() {
        for name in ["em-admin", "em-api", "SwiftIDE", "em-smtp-data", "Preview"] {
            #expect(ProjectIdentity.hue(for: name) == ProjectIdentity.hue(for: name))
            #expect(ProjectIdentity.hues.contains(ProjectIdentity.hue(for: name)))
        }
    }
}
