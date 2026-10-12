import AppKit
import AgentInfrastructure
import IDEApplication
import Testing
@testable import ChatUI

@MainActor
struct ChatInitialTests {
    @Test func panelUsesNativeTextKit2AndDoesNotStartARequestOnOpening() throws {
        _ = NSApplication.shared
        let session = AgentSession(provider: DemoAgentProvider())
        let panel = ChatPanelViewController(session: session)
        _ = panel.view
        defer {
            panel.disconnect()
            session.stop()
        }
        #expect(panel.input.textLayoutManager != nil)
        #expect(session.messages.isEmpty && session.state == .ready)
        #expect(!panel.send.isEnabled && panel.stop.isHidden)
    }

    @Test func replacingAnActivityDetailDoesNotSplitACommonSurrogatePrefix() {
        let text = ChatTextView()
        text.present("Result 🙂")
        text.present("Result 🙃")
        #expect(text.string == "Result 🙃")
        text.present("👩‍💻 context")
        text.present("👩‍🔬 context")
        #expect(text.string == "👩‍🔬 context" && text.textLayoutManager != nil)
    }
}
