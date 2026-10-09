import IDEApplication
import IDEDomain
import Testing

private typealias Kinds = [HighlightKind?]

private func kinds(of state: HighlightState, length: Int) -> Kinds {
    var result = Kinds(repeating: nil, count: length)
    var previousEnd = 0
    for span in state.spans {
        #expect(span.length > 0, "no empty spans")
        #expect(span.location >= previousEnd, "sorted and not overlapping")
        previousEnd = span.end
        for index in span.location..<span.end { result[index] = span.kind }
    }
    return result
}

private func spans(of kinds: Kinds, offset: Int = 0) -> [HighlightSpan] {
    var result: [HighlightSpan] = []
    var index = 0
    while index < kinds.count {
        guard let kind = kinds[index] else { index += 1; continue }
        var end = index + 1
        while end < kinds.count, kinds[end] == kind { end += 1 }
        result.append(HighlightSpan(location: offset + index, length: end - index, kind: kind))
        index = end
    }
    return result
}

private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

private func randomKinds(_ count: Int, _ generator: inout SeededGenerator) -> Kinds {
    let all = HighlightKind.allCases
    var result = Kinds(repeating: nil, count: count)
    var index = 0
    while index < count {
        let run = Int.random(in: 1...6, using: &generator)
        let kind: HighlightKind? = Bool.random(using: &generator) ? all.randomElement(using: &generator) : nil
        for position in index..<min(count, index + run) { result[position] = kind }
        index += run
    }
    return result
}

@Test
func editsMoveTrimAndSplitSpansLikeTheTextUnderThem() {
    var generator = SeededGenerator(state: 0x5AA5)
    for round in 0..<400 {
        var model = randomKinds(Int.random(in: 0...80, using: &generator), &generator)
        var state = HighlightState(window: 0..<model.count, spans: spans(of: model))
        for step in 0..<12 {
            let location = Int.random(in: 0...model.count, using: &generator)
            let length = Int.random(in: 0...min(8, model.count - location), using: &generator)
            let inserted = Int.random(in: 0...6, using: &generator)
            state.apply(edit: UTF16TextRange(location: location, length: length), replacementLength: inserted)
            model.replaceSubrange(location..<(location + length), with: Kinds(repeating: nil, count: inserted))
            #expect(kinds(of: state, length: model.count) == model, "round \(round) step \(step)")
        }
    }
}

@Test
func spansOverlappingARangeAreFoundByPosition() {
    let state = HighlightState(window: 0..<100, spans: [
        HighlightSpan(location: 2, length: 3, kind: .keyword),
        HighlightSpan(location: 10, length: 5, kind: .string),
        HighlightSpan(location: 40, length: 2, kind: .number)
    ])
    #expect(state.spans(overlapping: 0..<2).isEmpty)
    #expect(state.spans(overlapping: 0..<3).map(\.kind) == [.keyword])
    #expect(state.spans(overlapping: 4..<11).map(\.kind) == [.keyword, .string])
    #expect(state.spans(overlapping: 15..<40).isEmpty, "a span ending where the range starts is not in it")
    #expect(state.spans(overlapping: 0..<100).count == 3)
    #expect(state.spans(overlapping: 5..<5).isEmpty)
}

@Test
func theWindowFollowsEditsInsideBeforeAndAfterIt() {
    var state = HighlightState(window: 100..<200, spans: [])
    state.apply(edit: UTF16TextRange(location: 10, length: 0), replacementLength: 5)   // before
    #expect(state.window == 105..<205)
    state.apply(edit: UTF16TextRange(location: 300, length: 4), replacementLength: 0)   // after
    #expect(state.window == 105..<205)
    state.apply(edit: UTF16TextRange(location: 150, length: 0), replacementLength: 7)   // inside
    #expect(state.window == 105..<212)
    state.apply(edit: UTF16TextRange(location: 100, length: 20), replacementLength: 2)  // across the start
    #expect(state.window.lowerBound == 100)
    #expect(state.window.upperBound == 212 - 18)
}

@Test
func aFreshResultReplacesTheWindowAndKeepsWhatLiesOutsideIt() {
    var state = HighlightState(window: 0..<50, spans: [
        HighlightSpan(location: 0, length: 4, kind: .keyword),
        HighlightSpan(location: 20, length: 10, kind: .string),
        HighlightSpan(location: 45, length: 4, kind: .comment)
    ])
    state.replace(window: 10..<40, with: [HighlightSpan(location: 12, length: 3, kind: .number)])
    #expect(state.spans == [
        HighlightSpan(location: 0, length: 4, kind: .keyword),
        HighlightSpan(location: 12, length: 3, kind: .number),
        HighlightSpan(location: 45, length: 4, kind: .comment)
    ])
    #expect(state.window == 10..<40, "the window is what the latest answer describes, nothing more")
}

@Test
func aSpanStraddlingTheWindowEdgeKeepsItsOutsidePart() {
    var state = HighlightState(window: 0..<30, spans: [HighlightSpan(location: 8, length: 10, kind: .string)])
    state.replace(window: 12..<30, with: [])
    #expect(state.spans == [HighlightSpan(location: 8, length: 4, kind: .string)])
}

@Test
func aFreshResultReportsExactlyWhereColoursChanged() {
    var generator = SeededGenerator(state: 0xD1FF)
    for round in 0..<300 {
        let length = Int.random(in: 1...60, using: &generator)
        let old = randomKinds(length, &generator)
        let new = randomKinds(length, &generator)
        var state = HighlightState(window: 0..<length, spans: spans(of: old))
        let changed = state.replace(window: 0..<length, with: spans(of: new))
        var expected: [Range<Int>] = []
        for index in 0..<length where old[index] != new[index] {
            if let last = expected.last, last.upperBound == index {
                expected[expected.count - 1] = last.lowerBound..<(index + 1)
            } else {
                expected.append(index..<(index + 1))
            }
        }
        #expect(changed == expected, "round \(round)")
        #expect(kinds(of: state, length: length) == new)
    }
}

@Test
func stretchesAwaitingARedrawFollowEditsAndAreTakenByPlace() {
    var state = HighlightState()
    state.markDirty([10..<20, 18..<30, 100..<110])
    #expect(state.dirty == [10..<30, 100..<110], "touching stretches are joined")

    state.apply(edit: UTF16TextRange(location: 0, length: 0), replacementLength: 5)    // before: all move
    #expect(state.dirty == [15..<35, 105..<115])
    state.apply(edit: UTF16TextRange(location: 20, length: 0), replacementLength: 3)   // inside: grows
    #expect(state.dirty == [15..<38, 108..<118])
    state.apply(edit: UTF16TextRange(location: 200, length: 4), replacementLength: 0)  // after: untouched
    #expect(state.dirty == [15..<38, 108..<118])

    let taken = state.takeDirty(in: 30..<110)
    #expect(taken == [30..<38, 108..<110])
    #expect(state.dirty == [15..<30, 110..<118], "what lay outside stays")
    #expect(state.takeDirty(in: 0..<5).isEmpty)
}

@Test
func aDeletionSwallowingAStretchAwaitingARedrawLeavesNothingOfIt() {
    var state = HighlightState()
    state.markDirty([10..<20])
    state.apply(edit: UTF16TextRange(location: 5, length: 30), replacementLength: 0)
    #expect(state.dirty.isEmpty)
}
