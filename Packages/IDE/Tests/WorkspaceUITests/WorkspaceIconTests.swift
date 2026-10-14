import AppKit
import IDEApplication
import Testing
@testable import WorkspaceUI

@Suite(.serialized) @MainActor
struct WorkspaceIconTests {
    @Test func reusedFileCellsKeepSwiftAndDocumentIconsIndependentOfFinderAssociations() throws {
        let cell = FileStatusCell()
        cell.present(.init(path: "/w/Main.swift", isDirectory: false), message: nil, decoration: .init())
        let icon = try #require(cell.imageView)
        #expect(icon.image?.accessibilityDescription == "Swift source file")
        #expect(icon.image?.isTemplate == true)
        #expect(icon.image?.representations.contains { $0 is NSPDFImageRep } == true)
        #expect(icon.contentTintColor == .systemOrange)
        cell.backgroundStyle = .emphasized
        cell.present(.init(path: "/w/README.md", isDirectory: false), message: nil, decoration: .init())
        #expect(icon.image?.accessibilityDescription == "Document" && icon.image?.isTemplate == true)
        #expect(icon.contentTintColor == .alternateSelectedControlTextColor)
        cell.backgroundStyle = .normal
        #expect(icon.contentTintColor == .secondaryLabelColor)
        cell.present(.init(path: "/w/Sources", isDirectory: true), message: nil, decoration: .init())
        #expect(icon.image?.accessibilityDescription == "Folder" && icon.contentTintColor == .systemBlue)
        cell.present(.init(path: "/w/Link", isDirectory: true, isSymbolicLink: true), message: nil, decoration: .init())
        #expect(icon.image?.accessibilityDescription == "Linked folder")
        #expect(cell.accessibilityLabel()?.contains("Symbolic link") == true)
    }

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
