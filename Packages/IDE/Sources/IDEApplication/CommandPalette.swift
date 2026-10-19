import Foundation

/// One command the palette can list: what it is called, where it lives, how to press it and
/// whether it can run now. The application derives these from its single list of commands (the
/// main menu), so the palette never keeps a second copy of titles, shortcuts or availability.
public struct PaletteCommand: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    /// The menu path above the command, for example "Edit".
    public let group: String
    /// The shortcut as it is shown ("⌘/"), if the command has one.
    public let shortcut: String?
    public let isEnabled: Bool

    public init(id: String, title: String, group: String, shortcut: String? = nil, isEnabled: Bool = true) {
        self.id = id
        self.title = title
        self.group = group
        self.shortcut = shortcut
        self.isEnabled = isEnabled
    }
}

/// Finding commands by a few typed letters.
public enum CommandSearch {
    /// The commands that match every word of `query`, best first; commands that cannot run now come
    /// after those that can at the same quality. An empty query lists everything in menu order.
    /// A word matches if its letters appear in the title (or the group) in order; a match at the
    /// start, at the start of a word or in one run scores higher than letters scattered about.
    public static func rank(_ query: String, in commands: [PaletteCommand]) -> [PaletteCommand] {
        let words = query.lowercased().split(whereSeparator: { $0.isWhitespace }).map(Array.init)
        guard !words.isEmpty else {
            return commands.enumerated()
                .sorted { ($0.element.isEnabled ? 0 : 1, $0.offset) < ($1.element.isEnabled ? 0 : 1, $1.offset) }
                .map(\.element)
        }

        var scored: [(command: PaletteCommand, score: Int, order: Int)] = []
        for (order, command) in commands.enumerated() {
            let title = Array(command.title.lowercased())
            let group = Array(command.group.lowercased())
            var total = 0
            var matchedAll = true
            for word in words {
                let inTitle = score(word, in: title)
                let inGroup = score(word, in: group).map { $0 / 4 }
                guard let best = [inTitle, inGroup].compactMap({ $0 }).max() else {
                    matchedAll = false
                    break
                }

                total += best
            }
            if matchedAll { scored.append((command, total, order)) }
        }

        return scored.sorted {
            ($1.score, $0.command.isEnabled ? 0 : 1, $0.order) < ($0.score, $1.command.isEnabled ? 0 : 1, $1.order)
        }
        .map(\.command)
    }

    /// nil if `word` is not a subsequence of `text`; otherwise higher is better.
    static func score(_ word: [Character], in text: [Character]) -> Int? {
        guard !word.isEmpty else { return 0 }

        var best: Int?
        // Try each start so that a later, tighter match can beat an earlier, scattered one.
        for start in text.indices where text[start] == word[0] {
            var position = start
            var matched = 1
            var score = 100
            if start == 0 { score += 60 } else if isWordStart(text, start) { score += 30 }

            while matched < word.count {
                guard let next = text[(position + 1)...].firstIndex(of: word[matched]) else {
                    score = -1
                    break
                }

                score += next == position + 1 ? 20 : (isWordStart(text, next) ? 8 : -min(10, next - position))
                position = next
                matched += 1
            }
            if score >= 0 { best = max(best ?? score, score) }
        }

        return best
    }

    private static func isWordStart(_ text: [Character], _ index: Int) -> Bool {
        index == 0 || !text[index - 1].isLetter && !text[index - 1].isNumber
    }
}
