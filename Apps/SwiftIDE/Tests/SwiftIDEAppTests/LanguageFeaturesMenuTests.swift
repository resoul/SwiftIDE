import AppKit
import Testing
@testable import SwiftIDE

struct LanguageFeaturesMenuTests {
    @Test @MainActor func editMenuHasQuickHelpAndJumpToDefinitionWithTheirKeys() throws {
        _ = NSApplication.shared
        MainMenu.install()
        let edit = try #require(NSApp.mainMenu?.items.first { $0.submenu?.title == "Edit" }?.submenu)

        let quickHelp = try #require(edit.items.first { $0.title == "Quick Help" })
        #expect(quickHelp.action == #selector(WorkspaceWindowController.showQuickHelp(_:)))
        #expect(quickHelp.keyEquivalent == " " && quickHelp.keyEquivalentModifierMask == [.control, .shift])

        let jump = try #require(edit.items.first { $0.title == "Jump to Definition" })
        #expect(jump.action == #selector(WorkspaceWindowController.jumpToDefinition(_:)))
        #expect(jump.keyEquivalent == "j" && jump.keyEquivalentModifierMask == [.control, .command])

        let back = try #require(edit.items.first { $0.title == "Go Back" })
        #expect(back.action == #selector(AppDelegate.goBack(_:)))
        #expect(back.keyEquivalentModifierMask == [.control, .command])
    }

    @Test @MainActor func filesOfTheToolchainAndTheSDKAreToBeReadAndProjectsAreNot() {
        for path in [
            "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/include/stdio.h",
            "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/include/swift/x.h",
            "/Applications/Xcode-beta.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk/x.h",
            "/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/usr/include/stdio.h",
            "/usr/include/c++/v1/vector",
            "/System/Library/Frameworks/Foundation.framework/Headers/NSObject.h",
            "/var/folders/r_/xx/T/sourcekit-lsp/GeneratedInterfaces/1234/Swift.Misc.swiftinterface",
        ] {
            #expect(AppDelegate.isSystemFile(path), "\(path)")
        }
        for path in [
            "/Users/me/project/Sources/App/main.swift",
            "/tmp/a.c",
            "/Volumes/Work/Package.swift",
            "/Users/me/Applications/x.swift",
            "/Applications/MyApp/Sources/main.swift",
            "/opt/work/project/main.swift",
            "/Library/WebServer/project/x.swift",
            "/usr/local/src/project/main.c",
            "/Users/me/project/.build/checkouts/dep/Sources/Dep.swift",
        ] {
            #expect(!AppDelegate.isSystemFile(path), "\(path)")
        }
    }
}
