import Foundation
import IDEDomain

/// What jumping to a definition does on the screen.
@MainActor
public protocol DefinitionNavigating: AnyObject {
    /// The definition is in this document: put the caret there and show it.
    func moveCaret(to offset: Int)
    /// The definition is in another file: open it at that place.
    func open(_ location: DefinitionLocation)
    /// Nothing to jump to, or why not.
    func tell(_ message: String, at offset: Int)
    /// Several places: let the user choose one, near `offset`; `pick` goes there.
    func choose(among places: [DefinitionLocation], near offset: Int, pick: @escaping @MainActor (DefinitionLocation) -> Void)
}

/// Asks where the symbol at an offset is defined and goes there.
///
/// One place is gone to at once; several (without repeats) are offered to the user to choose from.
/// A newer jump replaces an older one still waiting; an answer for text that changed meanwhile is
/// dropped without a word.
@MainActor
public final class DefinitionController {
    private let session: DocumentSession
    private let provider: any DefinitionProviding
    /// Not owned: the owner of the controller is usually the navigator.
    public weak var navigator: (any DefinitionNavigating)?
    private var latest: UInt64 = 0

    public init(session: DocumentSession, provider: any DefinitionProviding, navigator: (any DefinitionNavigating)? = nil) {
        self.session = session
        self.provider = provider
        self.navigator = navigator
    }

    public func jump(from offset: Int) async {
        latest += 1
        let mine = latest
        let outcome = await provider.definition(for: session, offset: { offset })
        guard latest == mine, let navigator else { return }

        switch outcome {
        case .locations(let places):
            var distinct: [DefinitionLocation] = []
            for place in places where !distinct.contains(place) { distinct.append(place) }
            switch distinct.count {
            case 0: navigator.tell("No definition found", at: offset)
            case 1: go(to: distinct[0], navigator: navigator)
            default:
                navigator.choose(among: distinct, near: offset) { [weak self, weak navigator] place in
                    guard let self, let navigator else { return }

                    self.go(to: place, navigator: navigator)
                }
            }
        case .nothing:
            navigator.tell("No definition found", at: offset)
        case .failed(.unavailable(let reason)):
            navigator.tell(HoverController.words(for: reason), at: offset)
        case .failed(.stale), .failed(.suppressedByComposition):
            break
        }
    }

    private func go(to place: DefinitionLocation, navigator: any DefinitionNavigating) {
        if let target = place.offset {   // an offset is given only for a place in this document
            navigator.moveCaret(to: target)
        } else {
            navigator.open(place)
        }
    }
}
