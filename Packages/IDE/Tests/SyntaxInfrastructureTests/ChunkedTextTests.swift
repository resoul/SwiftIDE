import Foundation
import Testing
@testable import SyntaxInfrastructure

private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

@Test
func chunkedTextEqualsAPlainArrayThroughRandomEdits() {
    var generator = SeededGenerator(state: 0xC4A7)
    for round in 0..<40 {
        var model = (0..<Int.random(in: 0...90_000, using: &generator)).map { _ in UInt16.random(in: 0x61...0x7A, using: &generator) }
        var text = ChunkedText(chunks: stride(from: 0, to: model.count, by: 7_000).map { Array(model[$0..<min($0 + 7_000, model.count)]) })
        #expect(text.units == model)
        for step in 0..<25 {
            let location = Int.random(in: 0...model.count, using: &generator)
            let length = Int.random(in: 0...min(Bool.random(using: &generator) ? 40_000 : 20, model.count - location), using: &generator)
            let inserted = (0..<Int.random(in: 0...(Bool.random(using: &generator) ? 50_000 : 10), using: &generator)).map { _ in UInt16.random(in: 0x41...0x5A, using: &generator) }
            do { let ok = text.replace(location..<(location + length), with: inserted); #expect(ok) }
            model.replaceSubrange(location..<(location + length), with: inserted)
            #expect(text.length == model.count, "round \(round) step \(step)")
            if step % 8 == 0 { #expect(text.units == model, "round \(round) step \(step)") }
        }
        #expect(text.units == model)
    }
}

@Test
func chunkedTextReadsSubstringsAndParserBytesFromAnyPlace() {
    let model = (0..<50_000).map { UInt16(0x61 + $0 % 26) }
    let text = ChunkedText(chunks: [Array(model[..<20_000]), Array(model[20_000...])])
    #expect(text.substring(19_990..<20_010) == String(decoding: model[19_990..<20_010], as: UTF16.self), "across a chunk boundary")
    #expect(text.substring(0..<0) == "")
    #expect(text.bytes(fromUnit: 50_000) == nil)
    var covered = 0
    var offset = 0
    while let piece = text.bytes(fromUnit: offset) {
        #expect(piece.count % 2 == 0)
        let first = piece.withUnsafeBytes { $0.load(as: UInt16.self) }
        #expect(first == model[offset], "little-endian units from \(offset)")
        covered += piece.count / 2
        offset += piece.count / 2
    }
    #expect(covered == 50_000, "reading chunk by chunk covers everything")
}

@Test
func chunkedTextRejectsRangesOutsideItAndHandlesEmptiness() {
    var text = ChunkedText()
    #expect(text.length == 0)
    do { let ok = text.replace(0..<0, with: Array("abc".utf16)); #expect(ok) }
    #expect(text.units == Array("abc".utf16))
    do { let ok = text.replace(2..<9, with: []); #expect(!ok) }
    #expect(text.units == Array("abc".utf16))
    do { let ok = text.replace(0..<3, with: []); #expect(ok) }
    #expect(text.length == 0 && text.units.isEmpty)
    #expect(text.bytes(fromUnit: 0) == nil)
}
