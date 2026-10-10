import AppKit
@testable import EditorUI
import IDEDomain
import Testing

@MainActor
struct SyntaxThemeTests {
    private func rgb(_ colour: NSColor, in appearance: NSAppearance.Name) -> (Double, Double, Double) {
        var result = (0.0, 0.0, 0.0)
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
            let c = colour.usingColorSpace(.sRGB) ?? colour
            result = (Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
        }

        return result
    }

    /// Names in code (types, calls, members, constants) sit side by side; they must not read as one colour.
    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func typesFunctionsPropertiesAndConstantsAreToldApartInBothAppearances(appearance: NSAppearance.Name) throws {
        let theme = SyntaxTheme.standard
        let kinds: [HighlightKind] = [.type, .function, .property, .constant]
        let colours = try kinds.map { try #require(theme.colour(for: $0)) }.map { rgb($0, in: appearance) }

        for i in colours.indices {
            for j in colours.indices where j > i {
                let (a, b) = (colours[i], colours[j])
                let distance = ((a.0 - b.0) * (a.0 - b.0) + (a.1 - b.1) * (a.1 - b.1) + (a.2 - b.2) * (a.2 - b.2)).squareRoot()
                #expect(distance >= 0.2, "\(kinds[i]) and \(kinds[j]) are too alike in \(appearance.rawValue): \(distance)")
            }
        }
    }
}
