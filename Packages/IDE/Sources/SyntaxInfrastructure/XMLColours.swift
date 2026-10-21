import IDEDomain

/// Colours XML, and what the property-list files of Xcode need on top of it: the text of `<key>` is a
/// property, of `<string>` a string, of `<integer>` and `<real>` a number, `<true/>` and `<false/>` constants.
enum XMLColours {
    static func kinds(for text: [UInt16]) -> [UInt8] {
        var painter = Painter(count: text.count)
        let count = text.count
        var index = 0
        var isPlist = false
        var element: String?
        var textStart = 0

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

        func paintText(_ range: Range<Int>) {
            guard range.lowerBound < range.upperBound else { return }

            var kind: HighlightKind?
            if isPlist, let element {
                switch element {
                case "key": kind = .property
                case "string", "date", "data": kind = .string
                case "integer", "real": kind = .number
                default: break
                }
            }

            // Spaces and line breaks around the text are not part of it.
            var from = range.lowerBound, to = range.upperBound
            while from < to, Scan.isSpace(text[from]) || text[from] == 0x0A || text[from] == 0x0D { from += 1 }

            while to > from, Scan.isSpace(text[to - 1]) || text[to - 1] == 0x0A || text[to - 1] == 0x0D { to -= 1 }

            if let kind { painter.paint(from..<to, kind) }

            var scan = range.lowerBound
            while scan < range.upperBound {
                if text[scan] == 0x26, let end = (scan..<range.upperBound).first(where: { text[$0] == 0x3B }),
                   end - scan <= 12 {
                    painter.paint(scan..<(end + 1), .escape)
                    scan = end + 1
                } else {
                    scan += 1
                }
            }
        }

        while index < count {
            guard text[index] == 0x3C else {
                index += 1
                continue
            }

            paintText(textStart..<index)
            if starts("<!--", at: index) {
                let end = find("-->", from: index + 4).map { $0 + 3 } ?? count
                painter.paint(index..<end, .comment)
                index = end
            } else if starts("<![CDATA[", at: index) {
                let end = find("]]>", from: index + 9).map { $0 + 3 } ?? count
                painter.paint(index..<(index + 9), .attribute)
                painter.paint((index + 9)..<max(index + 9, end - 3), .string)
                if end >= 3, end - 3 >= index + 9 { painter.paint((end - 3)..<end, .attribute) }

                index = end
            } else if starts("<?", at: index) {
                let end = find("?>", from: index + 2).map { $0 + 2 } ?? count
                painter.paint(index..<end, .attribute)
                index = end
            } else if starts("<!", at: index) {
                // A declaration such as DOCTYPE; its brackets may hold more declarations.
                var depth = 0
                var end = index + 2
                while end < count {
                    if text[end] == 0x5B { depth += 1 }

                    if text[end] == 0x5D { depth -= 1 }

                    if text[end] == 0x3E, depth <= 0 {
                        end += 1
                        break
                    }

                    end += 1
                }

                painter.paint(index..<end, .attribute)
                index = end
            } else {
                var cursor = index + 1
                let isClosing = cursor < count && text[cursor] == 0x2F
                painter.paint(index, .operator)
                if isClosing {
                    painter.paint(cursor, .operator)
                    cursor += 1
                }

                let nameStart = cursor
                while cursor < count, !Scan.isSpace(text[cursor]), ![0x3E, 0x2F, 0x0A, 0x0D].contains(text[cursor]) {
                    cursor += 1
                }

                let name = Scan.string(text, nameStart..<cursor)
                painter.paint(nameStart..<cursor, isPlist && ["true", "false"].contains(name) ? .constant : .keyword)
                if name == "plist" { isPlist = true }

                // Attributes up to the end of the tag.
                var selfClosing = false
                while cursor < count, text[cursor] != 0x3E {
                    let unit = text[cursor]
                    if unit == 0x22 || unit == 0x27 {
                        let end = Scan.endOfQuoted(text, from: cursor, to: count, escapes: false)
                        painter.paint(cursor..<end, .string)
                        cursor = end
                    } else if unit == 0x2F {
                        painter.paint(cursor, .operator)
                        selfClosing = cursor + 1 < count && text[cursor + 1] == 0x3E
                        cursor += 1
                    } else if Scan.isSpace(unit) || unit == 0x0A || unit == 0x0D || unit == 0x3D {
                        cursor += 1
                    } else {
                        let start = cursor
                        while cursor < count, !Scan.isSpace(text[cursor]),
                              ![0x3D, 0x3E, 0x2F, 0x0A, 0x0D].contains(text[cursor]) {
                            cursor += 1
                        }

                        painter.paint(start..<cursor, .property)
                    }
                }
                if cursor < count { painter.paint(cursor, .operator) }

                element = isClosing || selfClosing ? nil : name
                index = min(count, cursor + 1)
            }

            textStart = index
        }
        paintText(textStart..<count)

        return painter.values
    }
}
