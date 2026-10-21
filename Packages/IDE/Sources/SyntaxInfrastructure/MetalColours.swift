import Foundation
import IDEDomain

/// Colours Metal Shading Language: C++ with its own keywords, address spaces, vector and matrix types,
/// texture types and `[[attributes]]`. A scanner, so that the words the C++ grammar does not know
/// (`kernel`, `device`, `float4`, `texture2d`) are coloured for what they are.
enum MetalColours {
    private static let keywords: Set<String> = [
        "if",
        "else",
        "for",
        "while",
        "do",
        "switch",
        "case",
        "default",
        "break",
        "continue",
        "return",
        "goto",
        "struct",
        "class",
        "enum",
        "union",
        "typedef",
        "namespace",
        "using",
        "template",
        "typename",
        "const",
        "static",
        "inline",
        "constexpr",
        "sizeof",
        "auto",
        "volatile",
        "extern",
        "operator",
        "public",
        "private",
        "protected",
        "new",
        "delete",
        "this",
        "decltype",
        "static_assert",
        "explicit",
        "friend",
        "mutable",
        "kernel",
        "vertex",
        "fragment",
        "mesh",
        "object",
        "visible",
        "intersection",
        "stage_in",
        "constant",
        "device",
        "thread",
        "threadgroup",
        "threadgroup_imageblock",
        "ray_data",
        "object_data",
        "access",
        "read",
        "write",
        "read_write",
        "sample",
        "filter",
        "address",
        "coord",
        "compare_func",
        "mip_filter"
    ]
    private static let constants: Set<String> = ["true", "false", "nullptr", "NULL", "INFINITY", "NAN", "M_PI_F"]
    private static let types: Set<String> = [
        "void",
        "bool",
        "char",
        "uchar",
        "short",
        "ushort",
        "int",
        "uint",
        "long",
        "ulong",
        "half",
        "float",
        "double",
        "size_t",
        "ptrdiff_t",
        "sampler",
        "array",
        "atomic_int",
        "atomic_uint",
        "atomic_bool",
        "atomic_ulong",
        "bfloat",
        "ray",
        "intersector",
        "acceleration_structure",
        "instance_acceleration_structure",
        "visible_function_table",
        "intersection_function_table",
        "imageblock",
        "indirect_command_buffer",
        "uint8_t",
        "int8_t",
        "uint16_t",
        "int16_t",
        "uint32_t",
        "int32_t",
        "uint64_t",
        "int64_t",
        "packed_float3",
        "packed_half3",
        "packed_int3",
        "packed_uint3",
        "packed_float2",
        "packed_float4"
    ]
    private static let vectorOrMatrix = try! NSRegularExpression(
        pattern: "^(packed_)?(bool|char|uchar|short|ushort|int|uint|long|ulong|half|float|double|bfloat)[2-4](x[2-4])?$"
    )
    private static let textureLike = try! NSRegularExpression(
        pattern: "^(texture|depth|texturecube|depthcube)([0-9a-z_]*)$"
    )

    static func kinds(for text: [UInt16]) -> [UInt8] {
        var painter = Painter(count: text.count)
        let count = text.count
        var index = 0
        var atLineStart = true
        while index < count {
            let unit = text[index]
            switch unit {
            case 0x0A, 0x0D:
                atLineStart = true
                index += 1
            case 0x20, 0x09:
                index += 1
            case 0x2F where index + 1 < count && text[index + 1] == 0x2F:
                var end = index
                while end < count, text[end] != 0x0A, text[end] != 0x0D { end += 1 }

                painter.paint(index..<end, .comment)
                index = end
            case 0x2F where index + 1 < count && text[index + 1] == 0x2A:
                var end = index + 2
                while end + 1 < count, !(text[end] == 0x2A && text[end + 1] == 0x2F) { end += 1 }

                end = min(count, end + 2)
                painter.paint(index..<end, .comment)
                index = end
                atLineStart = false
            case 0x23 where atLineStart:
                // A preprocessor line, with its continuations.
                var end = index
                while end < count {
                    if text[end] == 0x0A || text[end] == 0x0D {
                        if end > index, text[end - 1] == 0x5C {
                            end += 1
                            continue
                        }

                        break
                    }

                    end += 1
                }

                painter.paint(index..<end, .attribute)
                index = end
            case 0x22, 0x27:
                let end = Scan.endOfQuoted(text, from: index, to: lineEnd(text, index))
                painter.paint(index..<end, .string)
                if unit == 0x22 { Scan.paintEscapes(text, (index + 1)..<max(index + 1, end - 1), &painter) }

                index = end
                atLineStart = false
            case 0x5B where index + 1 < count && text[index + 1] == 0x5B:
                // An attribute: `[[buffer(0)]]`.
                var end = index + 2
                while end + 1 < count, !(text[end] == 0x5D && text[end + 1] == 0x5D) { end += 1 }

                end = min(count, end + 2)
                painter.paint(index..<end, .attribute)
                index = end
                atLineStart = false
            default:
                atLineStart = false
                if Scan.isDigit(unit) || (unit == 0x2E && index + 1 < count && Scan.isDigit(text[index + 1])) {
                    var end = index + 1
                    while end < count, Scan.isWordPart(text[end]) || text[end] == 0x2E
                        || ((text[end] == 0x2B || text[end] == 0x2D) && [0x65, 0x45].contains(text[end - 1])) {
                        end += 1
                    }

                    painter.paint(index..<end, .number)
                    index = end
                } else if Scan.isWordStart(unit) {
                    var end = index + 1
                    while end < count, Scan.isWordPart(text[end]) { end += 1 }

                    paintWord(text, index..<end, &painter)
                    index = end
                } else {
                    index += 1
                }
            }
        }

        return painter.values
    }

    private static func lineEnd(_ text: [UInt16], _ start: Int) -> Int {
        var end = start
        while end < text.count, text[end] != 0x0A, text[end] != 0x0D { end += 1 }

        return end
    }

    private static func paintWord(_ text: [UInt16], _ range: Range<Int>, _ painter: inout Painter) {
        let word = Scan.string(text, range)
        var after = range.upperBound
        while after < text.count, Scan.isSpace(text[after]) { after += 1 }

        let next: UInt16? = after < text.count ? text[after] : nil
        let nsRange = NSRange(location: 0, length: (word as NSString).length)
        if keywords.contains(word) {
            painter.paint(range, .keyword)
        } else if constants.contains(word) {
            painter.paint(range, .constant)
        } else if types.contains(word) || vectorOrMatrix.firstMatch(in: word, range: nsRange) != nil
            || textureLike.firstMatch(in: word, range: nsRange) != nil {
            painter.paint(range, .type)
        } else if next == 0x3A, after + 1 < text.count, text[after + 1] == 0x3A {
            painter.paint(range, .builtin)
        } else if next == 0x28 {
            painter.paint(range, .function)
        } else if word.count > 1, word.allSatisfy({ $0.isUppercase || $0 == "_" || $0.isNumber }) {
            painter.paint(range, .constant)
        }
    }
}
