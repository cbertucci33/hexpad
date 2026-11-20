import XCTest
@testable import HexpadKit

final class GutterGeometryTests: XCTestCase {

    // MARK: - logicalLine

    func testFirstLineAtOrBeforeFirstNewline() {
        let text = "hello\nworld"
        XCTAssertEqual(GutterGeometry.logicalLine(of: 0, in: text), 1)
        XCTAssertEqual(GutterGeometry.logicalLine(of: 5, in: text), 1)
    }

    func testSecondLineAfterFirstNewline() {
        let text = "hello\nworld"
        XCTAssertEqual(GutterGeometry.logicalLine(of: 6, in: text), 2)
        XCTAssertEqual(GutterGeometry.logicalLine(of: text.utf16.count, in: text), 2)
    }

    func testEmptyStringIsOneLine() {
        XCTAssertEqual(GutterGeometry.logicalLine(of: 0, in: ""), 1)
        XCTAssertEqual(GutterGeometry.lineCount(in: ""), 1)
    }

    func testBlankLinesCountIndividually() {
        let text = "a\n\n\nb"
        XCTAssertEqual(GutterGeometry.lineCount(in: text), 4)
        XCTAssertEqual(GutterGeometry.logicalLine(of: text.utf16.count, in: text), 4)
    }

    func testTrailingNewlineOpensFinalLine() {
        let text = "a\nb\n"
        XCTAssertEqual(GutterGeometry.lineCount(in: text), 3)
    }

    func testEmojiAndCombiningMarksCountOneLine() {
        // Family emoji (multi-scalar) + combining accent must not shift lines.
        let text = "👨‍👩‍👧‍👦 café\nnext"
        XCTAssertEqual(GutterGeometry.logicalLine(of: 0, in: text), 1)
        let utf16 = text.utf16
        let nextIndex = utf16.firstIndex(of: 0x0A).map { utf16.distance(from: utf16.startIndex, to: $0) + 1 }
            ?? utf16.count
        XCTAssertEqual(GutterGeometry.logicalLine(of: nextIndex, in: text), 2)
    }

    func testCJKDoesNotAffectLineCount() {
        let text = "日本語のテキスト\n次"
        XCTAssertEqual(GutterGeometry.lineCount(in: text), 2)
    }

    // MARK: - firstCharIndex

    func testFirstCharIndexRoundTripsLogicalLine() {
        let text = "one\ntwo\nthree\nfour"
        for line in 1...4 {
            let idx = GutterGeometry.firstCharIndex(of: line, in: text)
            XCTAssertEqual(GutterGeometry.logicalLine(of: idx, in: text), line,
                           "line \(line) round-trip")
        }
    }

    func testFirstCharIndexClampsPastEnd() {
        let text = "only\ntwo"
        XCTAssertEqual(GutterGeometry.firstCharIndex(of: 99, in: text), text.utf16.count)
    }

    func testFirstCharIndexWithSurrogatePairs() {
        let text = "😀\nnext" // leading astral char = 2 UTF-16 units
        XCTAssertEqual(GutterGeometry.firstCharIndex(of: 1, in: text), 0)
        XCTAssertEqual(GutterGeometry.firstCharIndex(of: 2, in: text), 3)
    }

    // MARK: - rowOriginY

    func testRowOriginUnflippedPassesThrough() {
        let y = GutterGeometry.rowOriginY(textViewHeight: 500, lineHeight: 18, rowHeight: 12,
                                          viewHeight: 500, flipped: false, topY: 100)
        XCTAssertEqual(y, 100)
    }

    func testRowOriginFlippedAlignsTopEdges() {
        // Text view and gutter same height; row top in text space (topY) maps
        // so that the number's TOP sits at the line's top visually.
        let viewH: CGFloat = 500, lineH: CGFloat = 18, rowH: CGFloat = 12
        let y = GutterGeometry.rowOriginY(textViewHeight: viewH, lineHeight: lineH, rowHeight: rowH,
                                          viewHeight: viewH, flipped: true, topY: 0)
        // Line 1 occupies [0,18] flipped → [482,500] ours; number drawn bottom-up
        // at 488 puts its top at 500 == line top.
        XCTAssertEqual(y, viewH - rowH)
    }

    func testRowOriginMonotonicInTopY() {
        // Deeper lines must map to strictly lower Y in our non-flipped space.
        let a = GutterGeometry.rowOriginY(textViewHeight: 500, lineHeight: 18, rowHeight: 12,
                                          viewHeight: 500, flipped: true, topY: 0)
        let b = GutterGeometry.rowOriginY(textViewHeight: 500, lineHeight: 24, rowHeight: 12,
                                          viewHeight: 500, flipped: true, topY: 18)
        XCTAssertGreaterThan(a, b)
    }

    func testRowOriginSurvivesTallUnicodeLines() {
        // An emoji line lays out taller; positions of later lines shift and
        // must follow their fragment topY, not a constant step.
        let emojiTop: CGFloat = 0, emojiH: CGFloat = 30
        let nextTop = emojiTop + emojiH
        let yEmoji = GutterGeometry.rowOriginY(textViewHeight: 400, lineHeight: emojiH, rowHeight: 12,
                                               viewHeight: 400, flipped: true, topY: emojiTop)
        let yNext = GutterGeometry.rowOriginY(textViewHeight: 400, lineHeight: 16, rowHeight: 12,
                                              viewHeight: 400, flipped: true, topY: nextTop)
        XCTAssertEqual(yEmoji - yNext, nextTop, "spacing follows laid-out height exactly")
    }

    func testRowOriginFlippedSubtractsScrollOffset() {
        // Scrolled 200pt down, the first visible document line sits at
        // topY == 200; it must land at the viewport top, not 200pt below it.
        let viewH: CGFloat = 500, rowH: CGFloat = 12
        let top = GutterGeometry.rowOriginY(textViewHeight: 1000, lineHeight: 18, rowHeight: rowH,
                                            viewHeight: viewH, flipped: true, topY: 200,
                                            scrollOffsetY: 200)
        XCTAssertEqual(top, viewH - rowH, "a scrolled row aligns with the viewport top")

        // A line one row lower lands one row lower in the gutter, still positive.
        let next = GutterGeometry.rowOriginY(textViewHeight: 1000, lineHeight: 18, rowHeight: rowH,
                                             viewHeight: viewH, flipped: true, topY: 218,
                                             scrollOffsetY: 200)
        XCTAssertEqual(top - next, 18, "rows below the viewport top keep their spacing")
    }
}
