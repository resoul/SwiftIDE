import AppKit
import Testing
@testable import WorkspaceUI

@Suite(.serialized) @MainActor
struct WorkspaceIconTests {
    @Test func builtinsAndCustomTablerToolsUseVectorsWhileSFSymbolsRemainAvailable() throws {
        for tool in WorkspaceTool.allCases {
            let image = try #require(WorkspaceIcon.image(tool.symbol, description: tool.title))
            #expect(image.isTemplate)
            #expect(image.representations.contains { $0 is NSPDFImageRep })
            #expect(image.accessibilityDescription == tool.title)
        }
        let docker = try #require(WorkspaceIcon.image("tabler:brand-docker", description: "Containers"))
        #expect(docker.representations.contains { $0 is NSPDFImageRep })
        #expect(WorkspaceIcon.image("shippingbox") != nil)
        #expect(WorkspaceIcon.image("tabler:unknown-icon") == nil)
    }
}
