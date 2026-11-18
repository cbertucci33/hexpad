import XCTest
@testable import HexpadKit

/// P17g-3: the pure half of the Column Editor. Per-row insertions run bottom-
/// most first through ``MultiCaretApplier`` (so offsets above each edit stay
/// valid), and the Number mode's sequence semantics are pinned here.
final class ColumnEditorInsertionTests: XCTestCase {

    // MARK: - Text mode

    func testInsertPerRowUsesBottomUpOrderAndRemapsCarets() {
        let text = "one\ntwo\nthree"
        let carets = [
            NSRange(location: 0, length: 0),
            NSRange(location: 4, length: 0),
            NSRange(location: 8, length: 0)
        ]

        let result = ColumnEditing.insertPerRow(["A", "BB", "CCC"],
                                                at: carets,
                                                in: text)

        XCTAssertEqual(result.text, "Aone\nBBtwo\nCCCthree")
        XCTAssertEqual(result.carets, [
            NSRange(location: 1, length: 0),
            NSRange(location: 7, length: 0),
            NSRange(location: 14, length: 0)
        ], "every caret sits just after its own insertion in the final text")
    }

    func testInsertPerRowReplacesRectangularCaretSpans() {
        let text = "abcdef\nghijkl"
        let rectangle = ColumnRectangle(start: TextPoint(line: 0, column: 1),
                                        end: TextPoint(line: 1, column: 3))
        let carets = ColumnEditing.carets(in: text, rectangle: rectangle).carets
        XCTAssertEqual(carets, [NSRange(location: 1, length: 2),
                                NSRange(location: 8, length: 2)])

        let result = ColumnEditing.insertPerRow(["1", "22"], at: carets, in: text)

        XCTAssertEqual(result.text, "a1def\ng22jkl")
        XCTAssertEqual(result.carets, [NSRange(location: 2, length: 0),
                                       NSRange(location: 9, length: 0)])
    }

    func testInsertPerRowWithFewerInsertionsLeavesLaterRowsEmpty() {
        let text = "one\ntwo\nthree"
        let carets = [NSRange(location: 0, length: 0),
                      NSRange(location: 4, length: 0),
                      NSRange(location: 8, length: 0)]

        let result = ColumnEditing.insertPerRow(["X"], at: carets, in: text)

        XCTAssertEqual(result.text, "Xone\ntwo\nthree")
        XCTAssertEqual(result.carets, [NSRange(location: 1, length: 0),
                                       NSRange(location: 5, length: 0),
                                       NSRange(location: 9, length: 0)])
    }

    func testInsertPerRowWithNoCaretsIsANoOp() {
        let result = ColumnEditing.insertPerRow(["X"], at: [], in: "abc")
        XCTAssertEqual(result.text, "abc")
        XCTAssertTrue(result.carets.isEmpty)
    }

    // MARK: - Number mode: repeat semantics

    func testRepeatOneIncrementsEveryRow() {
        XCTAssertEqual(ColumnEditing.numberSequence(initial: 5, step: 2, repeat: 1, rows: 4),
                       ["05", "07", "09", "11"])
    }

    func testRepeatThreeSharesEachNumberAcrossThreeRows() {
        XCTAssertEqual(ColumnEditing.numberSequence(initial: 1, step: 1, repeat: 3, rows: 7),
                       ["1", "1", "1", "2", "2", "2", "3"])
    }

    func testRepeatTwoWithGrowingNumbersKeepsThePadding() {
        XCTAssertEqual(ColumnEditing.numberSequence(initial: 9, step: 1, repeat: 2, rows: 5),
                       ["09", "09", "10", "10", "11"])
    }

    func testRepeatLargerThanRowsRepeatsTheInitialNumber() {
        XCTAssertEqual(ColumnEditing.numberSequence(initial: 7, step: 5, repeat: 10, rows: 3),
                       ["7", "7", "7"])
    }

    // MARK: - Number mode: width and bounds

    func testZeroPaddingUsesTheLongestStringInTheSequence() {
        // 8, 9, 10 -> every value occupies two characters.
        XCTAssertEqual(ColumnEditing.numberSequence(initial: 8, step: 1, repeat: 1, rows: 3),
                       ["08", "09", "10"])
        XCTAssertEqual(ColumnEditing.numberSequence(initial: 1, step: 9, repeat: 1, rows: 3),
                       ["01", "10", "19"])
    }

    func testNegativeValuesKeepTheSignInsideThePaddedWidth() {
        // 3, 2, 1, 0, -1: "-1" is the longest string, so digits are padded to
        // one place and the minus sign occupies the other one.
        XCTAssertEqual(ColumnEditing.numberSequence(initial: 3, step: -1, repeat: 1, rows: 5),
                       ["03", "02", "01", "00", "-1"])
    }

    func testNonPositiveRowsOrRepeatAreClamped() {
        XCTAssertEqual(ColumnEditing.numberSequence(initial: 1, step: 1, repeat: 1, rows: 0), [])
        XCTAssertEqual(ColumnEditing.numberSequence(initial: 1, step: 1, repeat: 1, rows: -3), [])
        XCTAssertEqual(ColumnEditing.numberSequence(initial: 1, step: 1, repeat: 0, rows: 3),
                       ["1", "2", "3"], "a repeat below one behaves like one")
        XCTAssertEqual(ColumnEditing.numberSequence(initial: 1, step: 1, repeat: -2, rows: 2),
                       ["1", "2"])
    }

    // MARK: - Together

    func testNumberSequenceFeedsPerRowInsertion() {
        let text = "a\nb\nc"
        let carets = ColumnEditing.carets(
            in: text,
            rectangle: ColumnRectangle(start: TextPoint(line: 0, column: 1),
                                       end: TextPoint(line: 2, column: 1))
        ).carets
        XCTAssertEqual(carets, [NSRange(location: 1, length: 0),
                                NSRange(location: 3, length: 0),
                                NSRange(location: 5, length: 0)])

        let numbers = ColumnEditing.numberSequence(initial: 1, step: 1, repeat: 1,
                                                   rows: carets.count)
        let result = ColumnEditing.insertPerRow(numbers, at: carets, in: text)

        XCTAssertEqual(result.text, "a1\nb2\nc3")
        XCTAssertEqual(result.carets, [NSRange(location: 2, length: 0),
                                       NSRange(location: 5, length: 0),
                                       NSRange(location: 8, length: 0)])
    }
}
