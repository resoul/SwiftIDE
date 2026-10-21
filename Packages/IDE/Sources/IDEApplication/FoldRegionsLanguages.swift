import Foundation

/// Folding for the languages whose blocks are not (only) between brackets: tags, indentation,
/// tables and shell keywords. Every region keeps its header and the line after the block visible.
extension FoldRegions {
    /// The start of every line, and the lines' contents (terminators left out).
    private static func lineRanges(_ text: [UInt16]) -> [Range<Int>] {
        var result: [Range<Int>] = []
        var start = 0
        let count = text.count
        while start <= count {
            var end = start
            while end < count, text[end] != 0x0A, text[end] != 0x0D { end += 1 }

            result.append(start..<end)
            if end >= count { break }

            start = end + ((text[end] == 0x0D && end + 1 < count && text[end + 1] == 0x0A) ? 2 : 1)
        }
        // A final terminator does not make another line.
        if result.count > 1, let last = result.last, last.isEmpty, last.lowerBound == count { result.removeLast() }

        return result
    }

    /// A region that hides the lines after `startLine` up to `endLine` (which stays visible); an
    /// `endLine` past the last line means "to the end of the text".
    private static func region(startLine: Int, endLine: Int, lines: [Range<Int>], length: Int) -> FoldRegion? {
        guard endLine - startLine >= 2, startLine + 1 < lines.count else { return nil }

        let hiddenStart = lines[startLine + 1].lowerBound
        let hiddenEnd = endLine < lines.count ? lines[endLine].lowerBound : length
        guard hiddenStart < hiddenEnd else { return nil }

        return FoldRegion(
            startLine: startLine,
            headerStart: lines[startLine].lowerBound,
            endLine: endLine,
            hidden: hiddenStart..<hiddenEnd
        )
    }

    /// One region per start line, the widest, in order.
    private static func outermost(_ regions: [FoldRegion]) -> [FoldRegion] {
        var best: [Int: FoldRegion] = [:]
        for region in regions where region.endLine > (best[region.startLine]?.endLine ?? -1) {
            best[region.startLine] = region
        }

        return best.values.sorted { $0.startLine < $1.startLine }
    }

    // MARK: XML

    /// Elements that run over several lines, and comments and CDATA that do.
    public static func computeXML(in text: [UInt16]) -> [FoldRegion] {
        let lines = lineRanges(text)
        var regions: [FoldRegion] = []
        var stack: [(name: String, line: Int)] = []
        var line = 0
        var index = 0
        let count = text.count

        func advanceLine(to offset: Int) {
            while line + 1 < lines.count, lines[line + 1].lowerBound <= offset { line += 1 }
        }

        func starts(_ literal: String, at position: Int) -> Bool {
            let units = Array(literal.utf16)
            guard position + units.count <= count else { return false }

            return Array(text[position..<(position + units.count)]) == units
        }

        func find(_ literal: String, from position: Int) -> Int? {
            var scan = position
            while scan < count {
                if starts(literal, at: scan) { return scan }

                scan += 1
            }

            return nil
        }

        func emit(_ startLine: Int, _ endLine: Int) {
            if let made = region(startLine: startLine, endLine: endLine, lines: lines, length: count) {
                regions.append(made)
            }
        }

        while index < count {
            guard text[index] == 0x3C else {
                index += 1
                continue
            }

            advanceLine(to: index)
            let openLine = line
            if starts("<!--", at: index) {
                let end = find("-->", from: index + 4).map { $0 + 3 } ?? count
                advanceLine(to: max(index, end - 1))
                emit(openLine, line)
                index = end
            } else if starts("<![CDATA[", at: index) {
                let end = find("]]>", from: index + 9).map { $0 + 3 } ?? count
                advanceLine(to: max(index, end - 1))
                emit(openLine, line)
                index = end
            } else if starts("<?", at: index) {
                index = find("?>", from: index + 2).map { $0 + 2 } ?? count
            } else if starts("<!", at: index) {
                index = find(">", from: index + 2).map { $0 + 1 } ?? count
            } else {
                var cursor = index + 1
                let isClosing = cursor < count && text[cursor] == 0x2F
                if isClosing { cursor += 1 }

                let nameStart = cursor
                while cursor < count, ![0x20, 0x09, 0x0A, 0x0D, 0x3E, 0x2F].contains(text[cursor]) { cursor += 1 }

                let name = String(decoding: text[nameStart..<cursor], as: UTF16.self)
                var selfClosing = false
                while cursor < count, text[cursor] != 0x3E {
                    if text[cursor] == 0x22 || text[cursor] == 0x27 {
                        let quote = text[cursor]
                        cursor += 1
                        while cursor < count, text[cursor] != quote { cursor += 1 }
                    } else if text[cursor] == 0x2F, cursor + 1 < count, text[cursor + 1] == 0x3E {
                        selfClosing = true
                    }

                    cursor += 1
                }
                advanceLine(to: min(cursor, max(0, count - 1)))
                if isClosing {
                    if let position = stack.lastIndex(where: { $0.name == name }) {
                        emit(stack[position].line, line)
                        stack.removeSubrange(position...)
                    }
                } else if !selfClosing {
                    stack.append((name, openLine))
                }

                index = min(count, cursor + 1)
            }
        }

        return outermost(regions)
    }

    // MARK: YAML

    /// A line and what is nested under it: the lines that are indented deeper.
    public static func computeYAML(in text: [UInt16]) -> [FoldRegion] {
        let lines = lineRanges(text)
        var regions: [FoldRegion] = []
        var stack: [(indent: Int, line: Int, hasChild: Bool)] = []
        // A block ends with its last line of content: blank lines and comments after it are not part of it.
        var lastContent = -1

        func close(_ entry: (indent: Int, line: Int, hasChild: Bool)) {
            guard entry.hasChild,
                  let made = region(startLine: entry.line, endLine: lastContent + 1, lines: lines, length: text.count)
            else { return }

            regions.append(made)
        }

        for (number, range) in lines.enumerated() {
            var index = range.lowerBound
            while index < range.upperBound, text[index] == 0x20 { index += 1 }

            // Blank lines and comments neither open nor close a block.
            guard index < range.upperBound, text[index] != 0x23, text[index] != 0x09 else { continue }

            let indent = index - range.lowerBound
            // Document markers start over.
            if indent == 0, range.count >= 3, text[range.lowerBound] == 0x2D || text[range.lowerBound] == 0x2E,
               text[range.lowerBound + 1] == text[range.lowerBound],
               text[range.lowerBound + 2] == text[range.lowerBound] {
                while let top = stack.popLast() { close(top) }

                lastContent = number
                continue
            }

            while let top = stack.last, indent <= top.indent {
                stack.removeLast()
                close(top)
            }
            if !stack.isEmpty { stack[stack.count - 1].hasChild = true }

            stack.append((indent, number, false))
            lastContent = number
        }
        while let top = stack.popLast() { close(top) }

        return outermost(regions)
    }

    // MARK: Sections (TOML, INI)

    /// Every `[table]` header folds the lines under it, up to the next header.
    public static func computeSections(in text: [UInt16]) -> [FoldRegion] {
        let lines = lineRanges(text)
        var headers: [Int] = []
        for (number, range) in lines.enumerated() {
            var index = range.lowerBound
            while index < range.upperBound, text[index] == 0x20 || text[index] == 0x09 { index += 1 }

            if index < range.upperBound, text[index] == 0x5B { headers.append(number) }
        }

        var regions: [FoldRegion] = []
        for (position, header) in headers.enumerated() {
            let next = position + 1 < headers.count ? headers[position + 1] : lines.count
            if let made = region(startLine: header, endLine: next, lines: lines, length: text.count) {
                regions.append(made)
            }
        }

        return regions
    }

    // MARK: Shell

    /// `if … fi`, `for`/`while`/`until`/`select … done`, `case … esac`, and the `{ … }` of functions.
    public static func computeShell(in text: [UInt16]) -> [FoldRegion] {
        let lines = lineRanges(text)
        var regions = compute(in: text, characterLiterals: false, pairs: .braces, hashComments: true)
        var stack: [(closer: String, line: Int)] = []
        let openers = ["if": "fi", "for": "done", "while": "done", "until": "done", "select": "done", "case": "esac"]
        let separators: Set<String> = [";", "|", "&&", "||", "&", "(", "{", "then", "do", "else", "elif", "!"]

        for (number, range) in lines.enumerated() {
            var line = String(decoding: text[range], as: UTF16.self)
            // A comment, and what is quoted, is not code.
            line = stripped(line)
            var previousIsSeparator = true
            for token in tokens(of: line) {
                if previousIsSeparator {
                    if let closer = openers[token] {
                        stack.append((closer, number))
                    } else if ["fi", "done", "esac"].contains(token),
                              let position = stack.lastIndex(where: { $0.closer == token }) {
                        if let made = region(
                            startLine: stack[position].line,
                            endLine: number,
                            lines: lines,
                            length: text.count
                        ) {
                            regions.append(made)
                        }

                        stack.removeSubrange(position...)
                    }
                }

                previousIsSeparator = separators.contains(token)
            }
        }

        return outermost(regions)
    }

    private static func stripped(_ line: String) -> String {
        var result = ""
        var quote: Character?
        for character in line {
            if let open = quote {
                if character == open { quote = nil }

                continue
            }

            if character == "\"" || character == "'" {
                quote = character
                result.append(" ")
                continue
            }

            if character == "#", result.last == nil || result.last == " " || result.last == "\t" { break }

            result.append(character)
        }

        return result
    }

    private static func tokens(of line: String) -> [String] {
        var tokens: [String] = []
        var word = ""

        func flush() {
            if !word.isEmpty { tokens.append(word) }

            word = ""
        }

        let characters = Array(line)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == " " || character == "\t" {
                flush()
            } else if character == ";" || character == "|" || character == "&" || character == "(" || character == "{" {
                flush()
                if index + 1 < characters.count, characters[index + 1] == character,
                   character != ";" && character != "(" && character != "{" {
                    tokens.append(String([character, character]))
                    index += 1
                } else {
                    tokens.append(String(character))
                }
            } else {
                word.append(character)
            }

            index += 1
        }
        flush()

        return tokens
    }
}
