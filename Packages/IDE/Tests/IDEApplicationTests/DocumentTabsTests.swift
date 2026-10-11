import IDEApplication
import IDEDomain
import Testing

@Suite @MainActor
struct DocumentTabsTests {
    @Test func identitySelectionReorderingAndNeighbours() {
        let tabs = DocumentTabs()
        let a = DocumentID(), b = DocumentID(), c = DocumentID()
        tabs.open(a); tabs.open(b); tabs.open(c)
        tabs.open(a)
        #expect(tabs.order == [a, b, c] && tabs.selected == a)
        tabs.move(a, to: 3)
        #expect(tabs.order == [b, c, a] && tabs.selected == a)
        tabs.move(a, to: 0)
        #expect(tabs.order == [a, b, c])
        tabs.select(b); tabs.remove(a)
        #expect(tabs.order == [b, c] && tabs.selected == b)
        tabs.remove(b)
        #expect(tabs.selected == c)
        tabs.remove(c)
        #expect(tabs.order.isEmpty && tabs.selected == nil)
    }
    @Test func invalidMovesSelectionsAndUnsubscriptionDoNotPublish() {
        let tabs = DocumentTabs()
        let a = DocumentID(), missing = DocumentID()
        var updates = 0
        let token = tabs.subscribe { updates += 1 }
        tabs.open(a)
        tabs.select(missing); tabs.remove(missing); tabs.move(missing, to: 0)
        tabs.move(a, to: -1); tabs.move(a, to: 2); tabs.move(a, to: 1)
        #expect(updates == 1 && tabs.selected == a)
        tabs.unsubscribe(token)
        tabs.remove(a)
        #expect(updates == 1)
    }
}
