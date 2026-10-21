import IDEDomain

/// Colours the key-value and directive files that have no grammar of their own: `.gitignore`,
/// `.xcconfig`, `.ini`, `.properties`, `.strings`, `.pbxproj`, a Makefile, a Dockerfile. What they have
/// in common is comments, quoted strings, `[sections]`, `key = value`, and `$(VARIABLES)`.
enum ConfigColours {
    private static let dockerInstructions: Set<String> = [
        "FROM",
        "RUN",
        "CMD",
        "LABEL",
        "EXPOSE",
        "ENV",
        "ADD",
        "COPY",
        "ENTRYPOINT",
        "VOLUME",
        "USER",
        "WORKDIR",
        "ARG",
        "ONBUILD",
        "STOPSIGNAL",
        "HEALTHCHECK",
        "SHELL",
        "MAINTAINER"
    ]
    private static let makeDirectives: Set<String> = [
        "include",
        "-include",
        "ifeq",
        "ifneq",
        "ifdef",
        "ifndef",
        "else",
        "endif",
        "define",
        "endef",
        "export",
        "override",
        "vpath",
        ".PHONY",
        ".DEFAULT",
        ".SUFFIXES"
    ]

    static func kinds(for text: [UInt16]) -> [UInt8] {
        var painter = Painter(count: text.count)
        var inBlockComment = false

        for line in Scan.lines(in: text) {
            var index = line.lowerBound
            if inBlockComment {
                let end = blockCommentEnd(text, from: index, to: line.upperBound)
                painter.paint(index..<end.index, .comment)
                guard end.closed else { continue }

                inBlockComment = false
                index = end.index
            }

            let first = Scan.skipSpaces(text, from: index, to: line.upperBound)
            guard first < line.upperBound else { continue }

            let lead = text[first]
            if lead == 0x23 || lead == 0x3B {
                painter.paint(first..<line.upperBound, .comment)
                continue
            }

            if lead == 0x5B, first + 1 < line.upperBound, lead == 0x5B {
                var close = first
                while close < line.upperBound, text[close] != 0x5D { close += 1 }

                if close < line.upperBound {
                    painter.paint(first..<(close + 1), .type)
                    index = close + 1
                }
            } else if lead == 0x21 {
                painter.paint(first, .operator)
                index = first + 1
            } else if isInstruction(text, from: first, to: line.upperBound) {
                var end = first
                while end < line.upperBound, Scan.isWordPart(text[end]) { end += 1 }

                painter.paint(first..<end, .keyword)
                index = end
            } else if let key = keyEnd(text, from: first, to: line.upperBound) {
                painter.paint(first..<key.end, .property)
                painter.paint(key.operatorRange, .operator)
                index = key.operatorRange.upperBound
            } else if makeDirectives.contains(Scan.string(
                text,
                first..<wordEnd(text, from: first, to: line.upperBound)
            )) {
                painter.paint(first..<wordEnd(text, from: first, to: line.upperBound), .keyword)
                index = wordEnd(text, from: first, to: line.upperBound)
            } else {
                index = first
            }

            scanValue(text, from: index, to: line.upperBound, &painter, inBlockComment: &inBlockComment)
        }

        return painter.values
    }

    private static func wordEnd(_ text: [UInt16], from start: Int, to end: Int) -> Int {
        var index = start
        while index < end, !Scan.isSpace(text[index]) { index += 1 }

        return index
    }

    private static func isInstruction(_ text: [UInt16], from start: Int, to end: Int) -> Bool {
        var index = start
        while index < end, text[index] >= 0x41 && text[index] <= 0x5A { index += 1 }

        guard index > start, index == end || Scan.isSpace(text[index]) else { return false }

        return dockerInstructions.contains(Scan.string(text, start..<index))
    }

    /// A key at the start of the line, and the `=` or `:` after it: `name = x`, `"key" = "value";`,
    /// `NAME := x`, `target: deps`. Not a key if the first thing is a value, a path or a pattern.
    private static func keyEnd(
        _ text: [UInt16],
        from start: Int,
        to end: Int
    ) -> (end: Int, operatorRange: Range<Int>)? {
        var index = start
        if text[index] == 0x22 {
            index = Scan.endOfQuoted(text, from: index, to: end)
        } else {
            while index < end, Scan.isWordPart(text[index]) || [
                0x2E,
                0x2D,
                0x5B,
                0x5D,
                0x2F,
                0x25,
                0x24,
                0x28,
                0x29,
                0x2A
            ].contains(text[index]) {
                index += 1
            }
        }

        guard index > start else { return nil }

        let keyEnd = index
        index = Scan.skipSpaces(text, from: index, to: end)
        guard index < end else { return nil }

        let unit = text[index]
        if unit == 0x3D, !(index + 1 < end && text[index + 1] == 0x3D) { return (keyEnd, index..<(index + 1)) }

        if [0x3A, 0x3F, 0x2B].contains(unit), index + 1 < end, text[index + 1] == 0x3D {
            return (keyEnd, index..<(index + 2))
        }

        if unit == 0x3A, !(index + 1 < end && text[index + 1] == 0x3A) { return (keyEnd, index..<(index + 1)) }

        return nil
    }

    private static func blockCommentEnd(_ text: [UInt16], from start: Int, to end: Int) -> (index: Int, closed: Bool) {
        var index = start
        while index + 1 < end {
            if text[index] == 0x2A, text[index + 1] == 0x2F { return (index + 2, true) }

            index += 1
        }

        return (end, false)
    }

    private static func scanValue(
        _ text: [UInt16],
        from start: Int,
        to end: Int,
        _ painter: inout Painter,
        inBlockComment: inout Bool
    ) {
        var index = start
        while index < end {
            let unit = text[index]
            if unit == 0x2F, index + 1 < end, text[index + 1] == 0x2F {
                painter.paint(index..<end, .comment)

                return
            }

            if unit == 0x2F, index + 1 < end, text[index + 1] == 0x2A {
                let close = blockCommentEnd(text, from: index + 2, to: end)
                painter.paint(index..<close.index, .comment)
                inBlockComment = !close.closed
                index = close.index
            } else if unit == 0x23, index == start || Scan.isSpace(text[index - 1]) {
                painter.paint(index..<end, .comment)

                return
            } else if unit == 0x22 || unit == 0x27 {
                let stop = Scan.endOfQuoted(text, from: index, to: end, escapes: unit == 0x22)
                painter.paint(index..<stop, .string)
                if unit == 0x22 { Scan.paintEscapes(text, (index + 1)..<max(index + 1, stop - 1), &painter) }

                index = stop
            } else if unit == 0x24, index + 1 < end, text[index + 1] == 0x28 || text[index + 1] == 0x7B {
                let close: UInt16 = text[index + 1] == 0x28 ? 0x29 : 0x7D
                var stop = index + 2
                while stop < end, text[stop] != close { stop += 1 }

                stop = min(end, stop + 1)
                painter.paint(index..<stop, .property)
                index = stop
            } else if Scan.isDigit(unit), index == start || !Scan.isWordPart(text[index - 1]) {
                var stop = index
                while stop < end, Scan.isWordPart(text[stop]) || text[stop] == 0x2E { stop += 1 }

                if Scan.isNumber(Scan.string(text, index..<stop)) { painter.paint(index..<stop, .number) }

                index = stop
            } else if Scan.isWordStart(unit), index == start || !Scan.isWordPart(text[index - 1]) {
                var stop = index
                while stop < end, Scan.isWordPart(text[stop]) { stop += 1 }

                if ["true", "false", "yes", "no", "YES", "NO", "TRUE", "FALSE", "null"].contains(Scan.string(
                    text,
                    index..<stop
                )) {
                    painter.paint(index..<stop, .constant)
                }

                index = stop
            } else {
                index += 1
            }
        }
    }
}
