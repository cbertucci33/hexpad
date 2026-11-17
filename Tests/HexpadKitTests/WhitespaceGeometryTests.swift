import XCTest
import HexpadKit

/// Pure tab-stop column math behind the Show Symbol whitespace and indent
/// guide rendering.
final class WhitespaceGeometryTests: XCTestCase {

    func testSpacesAdvanceOneColumnAndTabsRoundUpToTheNextStop() {
        let runs = WhitespaceGeometry.columnRuns(forLeadingWhitespace: "  \t ", tabSize: 4)
        XCTAssertEqual(runs, [
            WhitespaceGeometry.ColumnRun(startColumn: 0, endColumn: 1),
            WhitespaceGeometry.ColumnRun(startColumn: 1, endColumn: 2),
            WhitespaceGeometry.ColumnRun(startColumn: 2, endColumn: 4),
            WhitespaceGeometry.ColumnRun(startColumn: 4, endColumn: 5)
        ])
        XCTAssertEqual(WhitespaceGeometry.indentationColumns(forLeadingWhitespace: "  \t ",
                                                            tabSize: 4), 5)
    }

    func testIndentationIgnoresNonWhitespace() {
        XCTAssertEqual(WhitespaceGeometry.indentationColumns(forLeadingWhitespace: "        text",
                                                            tabSize: 4), 8)
        XCTAssertEqual(WhitespaceGeometry.indentationColumns(forLeadingWhitespace: "",
                                                            tabSize: 4), 0)
    }

    func testGuideColumnsStartAfterTheFirstStop() {
        // One stop or less is the line's own indentation, not a guide.
        XCTAssertEqual(WhitespaceGeometry.guideColumns(forLeadingWhitespace: "  ", tabSize: 4), [])
        XCTAssertEqual(WhitespaceGeometry.guideColumns(forLeadingWhitespace: "    ", tabSize: 4), [4])
        XCTAssertEqual(WhitespaceGeometry.guideColumns(forLeadingWhitespace: "      ", tabSize: 4), [4])
        XCTAssertEqual(WhitespaceGeometry.guideColumns(forLeadingWhitespace: "        ", tabSize: 4), [4, 8])
        XCTAssertEqual(WhitespaceGeometry.guideColumns(forLeadingWhitespace: "\t\t", tabSize: 4), [4, 8])
    }

    func testGuidesFollowTabsThatSkipStops() {
        // Two spaces, then a tab: the tab spans columns 2..<4, so the only stop
        // reached is 4.
        XCTAssertEqual(WhitespaceGeometry.guideColumns(forLeadingWhitespace: "  \t  ",
                                                       tabSize: 4), [4])
        // A tab at an unaligned column still lands on a stop.
        XCTAssertEqual(WhitespaceGeometry.guideColumns(forLeadingWhitespace: " \t", tabSize: 4), [4])
    }

    func testTabSizeIsClampedToOne() {
        XCTAssertEqual(WhitespaceGeometry.columnRuns(forLeadingWhitespace: "\t", tabSize: 0),
                       [WhitespaceGeometry.ColumnRun(startColumn: 0, endColumn: 1)])
        XCTAssertEqual(WhitespaceGeometry.guideColumns(forLeadingWhitespace: "  ", tabSize: 0),
                       [1, 2])
    }
}
