import XCTest
@testable import HexpadKit

final class DocumentSearchTests: XCTestCase {

    func testLineColumnAndContextForMultiLineText() {
        let text = "alpha\nbeta alpha\ngamma"
        let matches = SearchEngine.findAll(in: text, pattern: "alpha", options: [])

        XCTAssertEqual(matches.count, 2)
        XCTAssertEqual(matches[0].line, 1)
        XCTAssertEqual(matches[0].column, 1)
        XCTAssertEqual(matches[0].context, "alpha")
        XCTAssertEqual(matches[0].text, "alpha")
        XCTAssertEqual(matches[0].range, NSRange(location: 0, length: 5))

        XCTAssertEqual(matches[1].line, 2)
        XCTAssertEqual(matches[1].column, 6)
        XCTAssertEqual(matches[1].context, "beta alpha")
        XCTAssertEqual(matches[1].range, NSRange(location: 11, length: 5))
    }

    func testSeveralMatchesOnOneLineShareContext() {
        let text = "one two one three one"
        let matches = SearchEngine.findAll(in: text, pattern: "one", options: [])
        XCTAssertEqual(matches.map(\.column), [1, 9, 19])
        XCTAssertTrue(matches.allSatisfy { $0.context == text })
        XCTAssertTrue(matches.allSatisfy { $0.line == 1 })
    }

    func testColumnsAreOneBasedUTF16Offsets() {
        // The emoji is two UTF-16 code units, matching NSRange and NSTextView.
        let text = "a👍needle"
        let matches = SearchEngine.findAll(in: text, pattern: "needle", options: [])
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].line, 1)
        XCTAssertEqual(matches[0].column, 4)
        XCTAssertEqual(matches[0].range.location, 3)
    }

    func testContextIncludesRestOfLineButNoLineEnding() throws {
        let text = "before\n  hit after  \nnext"
        let match = try XCTUnwrap(SearchEngine.findAll(in: text, pattern: "hit", options: []).first)
        XCTAssertEqual(match.context, "  hit after  ")
        XCTAssertEqual(match.column, 3)
    }

    func testTrailingNewlineOpensFinalEmptyLine() {
        let text = "hit\n"
        let matches = SearchEngine.findAll(in: text, pattern: "hit", options: [])
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].line, 1)
        XCTAssertEqual(matches[0].context, "hit")
    }

    func testCRLFContextIsStripped() {
        let text = "first\r\nsecond hit\r\nthird"
        let matches = SearchEngine.findAll(in: text, pattern: "hit", options: [])
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].line, 2)
        XCTAssertEqual(matches[0].column, 8)
        XCTAssertEqual(matches[0].context, "second hit")
    }

    func testOptionsAreHonoured() {
        let text = "Hello hello HELLO hellos"
        // Case-insensitive by default; whole word excludes "hellos".
        let insensitive = SearchEngine.findAll(in: text, pattern: "hello",
                                               options: [.wholeWord])
        XCTAssertEqual(insensitive.count, 3)

        let sensitive = SearchEngine.findAll(in: text, pattern: "hello",
                                             options: [.caseSensitive, .wholeWord])
        XCTAssertEqual(sensitive.count, 1)
        XCTAssertEqual(sensitive[0].column, 7)
    }

    func testRegexMatchesReportFullMatchRange() {
        let text = "id=42\nid=7"
        let matches = SearchEngine.findAll(in: text, pattern: "id=\\d+", options: [.regex])
        XCTAssertEqual(matches.count, 2)
        XCTAssertEqual(matches.map(\.text), ["id=42", "id=7"])
        XCTAssertEqual(matches[0].line, 1)
        XCTAssertEqual(matches[1].line, 2)
    }

    func testRangeLimitedSearchKeepsAbsoluteCoordinates() {
        let text = "needle\nx needle y\nneedle"
        let scope = (text as NSString).range(of: "x needle y")
        let matches = SearchEngine.findAll(in: text, pattern: "needle",
                                          options: [], range: scope)
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].line, 2)
        XCTAssertEqual(matches[0].column, 3)
        XCTAssertEqual(matches[0].context, "x needle y")
    }

    func testEmptyPatternAndMissingMatchesReturnEmpty() {
        XCTAssertTrue(SearchEngine.findAll(in: "text", pattern: "", options: []).isEmpty)
        XCTAssertTrue(SearchEngine.findAll(in: "text", pattern: "absent", options: []).isEmpty)
        XCTAssertTrue(SearchEngine.findAll(in: "", pattern: "x", options: []).isEmpty)
    }
}
