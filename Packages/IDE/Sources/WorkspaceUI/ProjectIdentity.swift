import AppKit

/// A project's badge and accent, derived from its name so the same project keeps them across launches.
enum ProjectIdentity {
    static let hues: [CGFloat] = [0.0, 0.07, 0.36, 0.5, 0.6, 0.77, 0.9]

    /// First letter of the first and last words: `SwiftIDE` → `SI`, `em-admin` → `EA`, `preview` → `P`.
    static func monogram(for name: String) -> String {
        let words = words(in: name)
        guard let first = words.first?.first else { return "" }

        let last = words.count > 1 ? words[words.count - 1].first : nil

        return String([first, last].compactMap { $0 }).uppercased()
    }

    static func hue(for name: String) -> CGFloat {
        hues[Int(stableHash(name) % UInt64(hues.count))]
    }

    static func colour(for name: String) -> NSColor {
        NSColor(calibratedHue: hue(for: name), saturation: 0.6, brightness: 0.8, alpha: 1)
    }

    /// Splits on separators and camel-case boundaries: `SwiftIDE` → `Swift`, `IDE`; `IDEApp` → `IDE`, `App`.
    private static func words(in name: String) -> [String] {
        var words: [String] = []
        var current = ""
        let characters = Array(name)
        for (index, character) in characters.enumerated() {
            guard character.isLetter || character.isNumber else {
                if !current.isEmpty { words.append(current) }
                current = ""
                continue
            }

            if !current.isEmpty, character.isUppercase {
                let previous = characters[index - 1]
                let nextIsLower = index + 1 < characters.count && characters[index + 1].isLowercase
                if previous.isLowercase || previous.isNumber || (previous.isUppercase && nextIsLower) {
                    words.append(current)
                    current = ""
                }
            }

            current.append(character)
        }
        if !current.isEmpty { words.append(current) }

        return words
    }

    /// FNV-1a. `Hasher` is seeded per process, so it would change the colour on every launch.
    private static func stableHash(_ name: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in name.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }

        return hash
    }
}

/// The project's monogram in its accent colour, shown beside the project name.
@MainActor
final class ProjectBadgeView: NSView {
    init(name: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.backgroundColor = ProjectIdentity.colour(for: name).cgColor
        let letters = NSTextField(labelWithString: ProjectIdentity.monogram(for: name))
        letters.font = .systemFont(ofSize: 10, weight: .bold)
        letters.textColor = .white
        letters.alignment = .center
        letters.translatesAutoresizingMaskIntoConstraints = false
        addSubview(letters)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 20),
            heightAnchor.constraint(equalToConstant: 20),
            letters.centerXAnchor.constraint(equalTo: centerXAnchor),
            letters.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
