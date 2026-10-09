import Foundation
import IDEDomain

/// Read access to a document's text that costs nothing proportional to the document.
///
/// Edits are validated and described through this, so typing in a 100 MB file does not pay for
/// copying it. Offsets are UTF-16 code units, like every public range.
@MainActor
public protocol TextSource {
    var utf16Length: Int { get }
    func utf16Unit(at index: Int) -> UInt16
    /// The text of `range`. Cost is proportional to the range.
    func substring(in range: UTF16TextRange) -> String
    /// Hands the text of `range` to `body` in consecutive pieces. For readers that must see all of
    /// it once (the line index at open): O(range), without building one big string.
    func enumerateUTF16(in range: UTF16TextRange, using body: (UnsafeBufferPointer<UInt16>) -> Void)
}

extension TextSource {
    public func enumerateUTF16(in range: UTF16TextRange, using body: (UnsafeBufferPointer<UInt16>) -> Void) {
        let piece = 1 << 16
        var location = range.location
        let end = range.location + range.length
        while location < end {
            let length = min(piece, end - location)
            let units = Array(substring(in: UTF16TextRange(location: location, length: length)).utf16)
            units.withUnsafeBufferPointer(body)
            location += length
        }
    }
}

/// A string as a `TextSource`. Builds a UTF-16 array once, so it is for tests and small inputs;
/// editors provide their own storage-backed implementation.
@MainActor
public struct StringTextSource: TextSource {
    private let units: [UInt16]

    public init(_ text: String) {
        units = Array(text.utf16)
    }

    public var utf16Length: Int { units.count }
    public func utf16Unit(at index: Int) -> UInt16 { units[index] }

    public func substring(in range: UTF16TextRange) -> String {
        String(decoding: units[range.location..<(range.location + range.length)], as: UTF16.self)
    }
}

/// Bulk UTF-16 reading of an `NSString`, shared by the backends that store text in one.
public enum NSStringUnits {
    public static func enumerate(
        _ string: NSString, in range: UTF16TextRange, using body: (UnsafeBufferPointer<UInt16>) -> Void
    ) {
        let piece = 1 << 16
        var buffer = [UInt16](repeating: 0, count: min(piece, max(range.length, 1)))
        var location = range.location
        let end = range.location + range.length
        while location < end {
            let length = min(piece, end - location)
            buffer.withUnsafeMutableBufferPointer { pointer in
                string.getCharacters(pointer.baseAddress!, range: NSRange(location: location, length: length))
                body(UnsafeBufferPointer(rebasing: pointer[0..<length]))
            }
            location += length
        }
    }
}
