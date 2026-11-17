import XCTest
@testable import HexpadKit

final class HideLinesModelTests: XCTestCase {

    // MARK: - State

    func testHideMergesOverlappingAndAdjacentRanges() {
        var state = HideLinesState()
        XCTAssertTrue(state.isEmpty)

        XCTAssertTrue(state.hide(3...5))
        XCTAssertEqual(state.lineRanges, [3...5])

        // Overlapping extend the block.
        XCTAssertTrue(state.hide(4...7))
        XCTAssertEqual(state.lineRanges, [3...7])

        // Adjacent lines join the same block, so the margin has one symbol.
        XCTAssertTrue(state.hide(8...8))
        XCTAssertEqual(state.lineRanges, [3...8])

        // Re-hiding an already hidden range is not a change.
        XCTAssertFalse(state.hide(4...6))
        XCTAssertEqual(state.lineRanges, [3...8])
    }

    func testHideKeepsRangesSortedAndSeparate() {
        var state = HideLinesState()
        state.hide(9...10)
        state.hide(2...3)
        XCTAssertEqual(state.lineRanges, [2...3, 9...10])

        state.hide(5...5)
        XCTAssertEqual(state.lineRanges, [2...3, 5...5, 9...10])
    }

    func testUnhideRemovesEveryIntersectingRangeWhole() {
        var state = HideLinesState(lineRanges: [2...3, 5...6, 9...10])

        // A range that touches any part of a block removes the whole block:
        // this is what a marker click and a selection that crosses the block
        // ask for.
        XCTAssertTrue(state.unhide(6...6))
        XCTAssertEqual(state.lineRanges, [2...3, 9...10])

        XCTAssertFalse(state.unhide(4...4))
        XCTAssertEqual(state.lineRanges, [2...3, 9...10])

        XCTAssertEqual(state.unhideAll(), 2)
        XCTAssertTrue(state.isEmpty)
    }

    func testStateClampsNonPositiveLineNumbers() {
        var state = HideLinesState()
        XCTAssertTrue(state.hide(0...2))
        XCTAssertEqual(state.lineRanges, [1...2])
        XCTAssertFalse(state.hide(-4...(-2)), "a wholly non-positive range is ignored")
        XCTAssertEqual(state.lineRanges, [1...2])
    }

    // MARK: - Character spans

    func testCharacterRangesIncludeTheTrailingNewline() {
        // 5 lines, no trailing newline.
        let text = "one\ntwo\nthree\nfour\nfive"

        var state = HideLinesState()
        state.hide(2...3)
        XCTAssertEqual(HideLinesVisibility.characterRanges(for: state, in: text),
                       [NSRange(location: 4, length: 10)],
                       "hides \"two\\nthree\\n\" including the newline that ends the block")
    }

    func testHidingTheLastLineHidesToEndOfDocument() {
        let text = "one\ntwo\nthree\nfour\nfive"
        var state = HideLinesState()
        state.hide(5...5)

        XCTAssertEqual(HideLinesVisibility.characterRanges(for: state, in: text),
                       [NSRange(location: 19, length: 4)])
    }

    func testStaleRangesBeyondTheTextHideNothing() {
        let text = "a\nb\nc"
        var state = HideLinesState()
        state.hide(9...12)

        XCTAssertTrue(HideLinesVisibility.characterRanges(for: state, in: text).isEmpty)
        XCTAssertNil(state.displayNumber(forLine: 9, lineCount: 3))
    }

    func testEmptyTrailingLineHasNoSpan() {
        // A trailing newline opens an empty final line; hiding it removes
        // nothing, so the mask stays empty instead of producing a zero range.
        let text = "a\n"
        var state = HideLinesState()
        state.hide(2...2)

        XCTAssertTrue(HideLinesVisibility.characterRanges(for: state, in: text).isEmpty)
    }

    // MARK: - Renumbering

    func testVisibleLinesAreRenumberedAfterAHiddenBlock() {
        var state = HideLinesState()
        state.hide(3...5)

        XCTAssertEqual(state.displayNumber(forLine: 1, lineCount: 8), 1)
        XCTAssertEqual(state.displayNumber(forLine: 2, lineCount: 8), 2)
        XCTAssertNil(state.displayNumber(forLine: 3, lineCount: 8))
        XCTAssertNil(state.displayNumber(forLine: 5, lineCount: 8))
        XCTAssertEqual(state.displayNumber(forLine: 6, lineCount: 8), 3,
                       "the first visible line after the block takes the next number")
        XCTAssertEqual(state.displayNumber(forLine: 8, lineCount: 8), 5)
        XCTAssertNil(state.displayNumber(forLine: 9, lineCount: 8), "past the end")
    }

    func testVisibleLineCountClipsStaleRanges() {
        var state = HideLinesState()
        state.hide(2...4)
        state.hide(9...12)

        XCTAssertEqual(state.hiddenLineCount(lineCount: 6), 3)
        XCTAssertEqual(state.visibleLineCount(lineCount: 6), 3)
        XCTAssertEqual(state.hiddenLineCount(before: 3), 1)
        XCTAssertEqual(state.hiddenLineCount(before: 1), 0)
    }

    func testAnchorIsTheLastVisibleLineAboveTheRange() {
        var state = HideLinesState()
        state.hide(3...5)
        XCTAssertEqual(state.anchorLine(for: 3...5, lineCount: 8), 2)

        // A block starting on line 1 has no line above it, so the marker moves
        // to the first visible line below.
        var leading = HideLinesState()
        leading.hide(1...2)
        XCTAssertEqual(leading.anchorLine(for: 1...2, lineCount: 8), 3)

        var trailing = HideLinesState()
        trailing.hide(7...8)
        XCTAssertEqual(trailing.anchorLine(for: 7...8, lineCount: 8), 6)

        // Fully hidden: no visible row can carry the symbol.
        var all = HideLinesState()
        all.hide(1...8)
        XCTAssertNil(all.anchorLine(for: 1...8, lineCount: 8))
        XCTAssertEqual(all.visibleLineCount(lineCount: 8), 0)
    }

    // MARK: - Session

    func testSessionRoundTripPreservesRanges() {
        var state = HideLinesState()
        state.hide(2...3)
        state.hide(7...8)

        let data = state.toSessionData()
        let restored = HideLinesState.fromSessionData(data)
        XCTAssertEqual(restored, state)
    }

    func testSessionRoundTripThroughJSONSerialization() throws {
        var state = HideLinesState()
        state.hide(4...6)

        let data = try JSONSerialization.data(withJSONObject: state.toSessionData())
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let restored = HideLinesState.fromSessionData(object)

        XCTAssertEqual(restored, state, "NSNumber values from JSON must parse")
    }

    func testMalformedSessionEntriesAreSkippedIndividually() {
        let data: [String: Any] = [
            "ranges": [
                ["start": 3, "end": 5],
                ["start": 0, "end": 2],        // invalid start
                ["start": 7, "end": 4],        // end before start
                ["start": "8", "end": 9],      // wrong type
                ["start": 9],                  // missing end
                ["start": 11, "end": 11]
            ]
        ]

        let state = HideLinesState.fromSessionData(data)
        XCTAssertEqual(state.lineRanges, [3...5, 11...11])
    }

    func testMissingSessionDataRestoresEmptyState() {
        XCTAssertTrue(HideLinesState.fromSessionData(nil).isEmpty)
        XCTAssertTrue(HideLinesState.fromSessionData([:]).isEmpty)
        XCTAssertTrue(HideLinesState.fromSessionData(["ranges": "nope"]).isEmpty)
    }

    func testEditorStateSessionCarriesHiddenRanges() {
        var state = DocumentEditorState()
        state.hiddenLinesState.hide(2...4)

        let restored = DocumentEditorState.fromSessionData(state.toSessionData())
        XCTAssertEqual(restored, state)
        XCTAssertEqual(restored.hiddenLinesState.lineRanges, [2...4])
    }

    func testOlderEditorStateWithoutHiddenRangesRestoresEmpty() {
        let restored = DocumentEditorState.fromSessionData(["wordWrap": true])
        XCTAssertTrue(restored.hiddenLinesState.isEmpty)
        XCTAssertTrue(restored.wordWrapEnabled)
    }
}
