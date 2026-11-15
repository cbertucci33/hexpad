import XCTest
@testable import HexpadKit

final class ColumnEditingTests: XCTestCase {

    // MARK: - Rectangle to carets

    func testRectangleProducesOneCaretPerLine() {
        // "alpha" 0..<5, "bravo" 6..<11, "charlie" 12..<19, "delta" 20..<25.
        let text = "alpha\nbravo\ncharlie\ndelta"
        let rectangle = ColumnRectangle(
            start: TextPoint(line: 1, column: 1),
            end: TextPoint(line: 3, column: 3)
        )

        let state = ColumnEditing.carets(in: text, rectangle: rectangle)

        XCTAssertEqual(state.carets, [
            NSRange(location: 7, length: 2),    // "ra" in "bravo"
            NSRange(location: 13, length: 2),   // "ha" in "charlie"
            NSRange(location: 21, length: 2)    // "el" in "delta"
        ])
        XCTAssertTrue(state.isValid)
    }

    func testRectangleNormalizesReversedCorners() {
        let text = "alpha\nbravo\ncharlie\ndelta"
        let forward = ColumnRectangle(
            start: TextPoint(line: 1, column: 1),
            end: TextPoint(line: 3, column: 3)
        )
        let reversed = ColumnRectangle(
            start: TextPoint(line: 3, column: 3),
            end: TextPoint(line: 1, column: 1)
        )

        XCTAssertEqual(ColumnEditing.carets(in: text, rectangle: reversed),
                       ColumnEditing.carets(in: text, rectangle: forward))
    }

    func testSingleLineRectangleProducesOneCaret() {
        // "one" 0..<3, "two" 4..<7, "three" 8..<13.
        let text = "one\ntwo\nthree"
        let rectangle = ColumnRectangle(
            start: TextPoint(line: 1, column: 1),
            end: TextPoint(line: 1, column: 3)
        )

        let state = ColumnEditing.carets(in: text, rectangle: rectangle)

        XCTAssertEqual(state.carets, [NSRange(location: 5, length: 2)]) // "wo"
        XCTAssertEqual(state.count, 1)
    }

    func testZeroWidthRectangleProducesInsertionPoints() {
        let text = "ab\ncd"
        let rectangle = ColumnRectangle(
            start: TextPoint(line: 0, column: 1),
            end: TextPoint(line: 1, column: 1)
        )

        XCTAssertEqual(ColumnEditing.carets(in: text, rectangle: rectangle).carets, [
            NSRange(location: 1, length: 0),
            NSRange(location: 4, length: 0)
        ])
    }

    func testShortLinesAreTruncatedAtEndOfLine() {
        // "abcdef" 0..<6, "abc" 7..<10, "ab" 11..<13.
        let text = "abcdef\nabc\nab"
        let rectangle = ColumnRectangle(
            start: TextPoint(line: 0, column: 1),
            end: TextPoint(line: 2, column: 4)
        )

        XCTAssertEqual(ColumnEditing.carets(in: text, rectangle: rectangle).carets, [
            NSRange(location: 1, length: 3),   // "bcd"
            NSRange(location: 8, length: 2),   // "bc", truncated at EOL
            NSRange(location: 12, length: 1)   // "b", truncated at EOL
        ])
    }

    // MARK: - Ragged lines

    func testRaggedLinesGetZeroLengthCaretsAtEndOfLine() {
        // "abcdef" 0..<6, "a" 7..<8, "abcd" 10..<14.
        let text = "abcdef\na\nabcd"
        let rectangle = ColumnRectangle(
            start: TextPoint(line: 0, column: 2),
            end: TextPoint(line: 2, column: 4)
        )

        XCTAssertEqual(ColumnEditing.carets(in: text, rectangle: rectangle).carets, [
            NSRange(location: 2, length: 2),   // "cd"
            NSRange(location: 8, length: 0),   // line "a" is too short: EOL caret
            NSRange(location: 11, length: 2)   // "cd"
        ])
    }

    func testRaggedLinesCanSkipLinesShorterThanTheStartColumn() {
        let text = "abcdef\na\nabcd"
        let rectangle = ColumnRectangle(
            start: TextPoint(line: 0, column: 2),
            end: TextPoint(line: 2, column: 4),
            raggedLinePolicy: .skipShortLines
        )

        XCTAssertEqual(ColumnEditing.carets(in: text, rectangle: rectangle).carets, [
            NSRange(location: 2, length: 2),
            NSRange(location: 11, length: 2)
        ])
    }

    // MARK: - Line terminators

    func testCRLFDocumentUsesLogicalLineColumns() {
        // "abc" 0..<3, "def" 5..<8, "ghi" 10..<13; each separator is two units.
        let text = "abc\r\ndef\r\nghi"
        let lines = ColumnEditing.lines(in: text)

        XCTAssertEqual(lines.map(\.contentRange), [
            NSRange(location: 0, length: 3),
            NSRange(location: 5, length: 3),
            NSRange(location: 10, length: 3)
        ])
        XCTAssertEqual(lines.map(\.terminatorLength), [2, 2, 0])

        let rectangle = ColumnRectangle(
            start: TextPoint(line: 0, column: 1),
            end: TextPoint(line: 2, column: 3)
        )

        XCTAssertEqual(ColumnEditing.carets(in: text, rectangle: rectangle).carets, [
            NSRange(location: 1, length: 2),    // "bc"
            NSRange(location: 6, length: 2),    // "ef"
            NSRange(location: 11, length: 2)    // "hi"
        ])
    }

    func testColumnsAreUTF16Offsets() {
        // The emoji is two UTF-16 units: "a" 0, emoji 1..<3, "b" 3.
        let text = "a😀b\ncd"
        let rectangle = ColumnRectangle(
            start: TextPoint(line: 0, column: 1),
            end: TextPoint(line: 0, column: 3)
        )

        XCTAssertEqual(ColumnEditing.carets(in: text, rectangle: rectangle).carets, [
            NSRange(location: 1, length: 2)
        ])
    }

    // MARK: - Bounds

    func testRectangleOutsideDocumentIsClamped() {
        let text = "abc"
        let clamped = ColumnRectangle(
            start: TextPoint(line: 0, column: 5),
            end: TextPoint(line: 4, column: 9)
        )
        let skipping = ColumnRectangle(
            start: TextPoint(line: 0, column: 5),
            end: TextPoint(line: 4, column: 9),
            raggedLinePolicy: .skipShortLines
        )

        XCTAssertEqual(ColumnEditing.carets(in: text, rectangle: clamped).carets, [
            NSRange(location: 3, length: 0)
        ])
        XCTAssertTrue(ColumnEditing.carets(in: text, rectangle: skipping).isEmpty)
    }

    func testEmptyDocumentProducesSingleCaret() {
        let rectangle = ColumnRectangle(
            start: TextPoint(line: 0, column: 0),
            end: TextPoint(line: 0, column: 0)
        )

        XCTAssertEqual(ColumnEditing.carets(in: "", rectangle: rectangle).carets, [
            NSRange(location: 0, length: 0)
        ])
    }

    // MARK: - Column operations

    func testInsertionAtEveryCaret() {
        let text = "one\ntwo\nthree"
        let state = MultiCaretState(carets: [
            NSRange(location: 0, length: 0),
            NSRange(location: 4, length: 0),
            NSRange(location: 8, length: 0)
        ])

        let result = ColumnEditing.insert("> ", into: text, state: state)

        XCTAssertEqual(result.text, "> one\n> two\n> three")
        XCTAssertEqual(result.state.carets, [
            NSRange(location: 2, length: 0),
            NSRange(location: 8, length: 0),
            NSRange(location: 14, length: 0)
        ])
        XCTAssertTrue(result.state.isValid)
    }

    func testInsertionReplacesRectangularSelection() {
        // "abcdef" 0..<6, "ghijkl" 7..<13.
        let text = "abcdef\nghijkl"
        let rectangle = ColumnRectangle(
            start: TextPoint(line: 0, column: 1),
            end: TextPoint(line: 1, column: 3)
        )

        let result = ColumnEditing.insert("X", into: text, rectangle: rectangle)

        XCTAssertEqual(result.text, "aXdef\ngXjkl")
        XCTAssertEqual(result.state.carets, [
            NSRange(location: 2, length: 0),
            NSRange(location: 8, length: 0)
        ])
    }

    func testRectangleDeleteRemovesColumnSpanOnEveryLine() {
        // "abcdef" 0..<6, "ab" 7..<9, "abcd" 10..<14.
        let text = "abcdef\nab\nabcd"
        let rectangle = ColumnRectangle(
            start: TextPoint(line: 0, column: 1),
            end: TextPoint(line: 2, column: 3)
        )

        let result = ColumnEditing.delete(in: text, rectangle: rectangle)

        XCTAssertEqual(result.text, "adef\na\nad")
        XCTAssertEqual(result.state.carets, [
            NSRange(location: 1, length: 0),
            NSRange(location: 6, length: 0),
            NSRange(location: 8, length: 0)
        ])
    }

    func testLineOpsTransformAppliesAtEveryColumnCaret() {
        let text = "alpha\nbravo\ncharlie"
        let rectangle = ColumnRectangle(
            start: TextPoint(line: 0, column: 0),
            end: TextPoint(line: 1, column: 2)
        )
        let state = ColumnEditing.carets(in: text, rectangle: rectangle)

        let fromRectangle = ColumnEditing.apply(LineOps.uppercase, to: text, rectangle: rectangle)
        let fromState = ColumnEditing.apply(LineOps.uppercase, to: text, state: state)

        XCTAssertEqual(fromRectangle.text, "ALpha\nBRavo\ncharlie")
        XCTAssertEqual(fromRectangle.state.carets, [
            NSRange(location: 0, length: 2),
            NSRange(location: 6, length: 2)
        ])
        XCTAssertEqual(fromState.text, fromRectangle.text)
        XCTAssertEqual(fromState.state, fromRectangle.state)
    }
}
