import XCTest
@testable import HexpadKit

/// P17a: the N++ Line Operations commands that were missing from the registry.
/// Sort semantics are pinned here: numeric lines lead (ascending or descending),
/// lines without numbers trail in their original relative order, and ties are
/// stable. Trim ops rewrite line content but never remove a line.
final class LineOpsExpansionTests: XCTestCase {

    // MARK: - Integer sorts

    func testSortLinesIntegerAscendingComparesByValue() {
        XCTAssertEqual(LineOps.sortLinesIntegerAscending("10\n2\n1\n20"),
                       "1\n2\n10\n20")
    }

    func testSortLinesIntegerDescendingComparesByValue() {
        XCTAssertEqual(LineOps.sortLinesIntegerDescending("10\n2\n1\n20"),
                       "20\n10\n2\n1")
    }

    func testIntegerSortKeepsNonNumericLinesAtTheEndInRelativeOrder() {
        let input = "beta\n10\nalpha\n2"
        XCTAssertEqual(LineOps.sortLinesIntegerAscending(input), "2\n10\nbeta\nalpha")
        XCTAssertEqual(LineOps.sortLinesIntegerDescending(input), "10\n2\nbeta\nalpha")
    }

    func testIntegerSortHandlesSeveralNumbersPerLineAndLeadingZeros() {
        XCTAssertEqual(LineOps.sortLinesIntegerAscending("xyz11\nxyz9\n192.168.0.1\n8.8.8.8"),
                       "xyz9\nxyz11\n8.8.8.8\n192.168.0.1")
        // Leading spaces are a text prefix, which sorts before a bare number.
        XCTAssertEqual(LineOps.sortLinesIntegerAscending("1000\n 100\n  10\n   1"),
                       " 100\n  10\n   1\n1000")
    }

    func testIntegerSortIsStableForEqualNumericKeys() {
        // "a10" and "a010" have the same key, so they keep their relative order
        // while both still precede the distinct "b10" key.
        XCTAssertEqual(LineOps.sortLinesIntegerAscending("a10\nb10\na010"),
                       "a10\na010\nb10")
    }

    // MARK: - Decimal sorts

    func testSortLinesDecimalAscendingComparesByValue() {
        XCTAssertEqual(LineOps.sortLinesDecimalAscending("10.234\n9.876\n2.5"),
                       "2.5\n9.876\n10.234")
        XCTAssertEqual(LineOps.sortLinesDecimalAscending("10\n9.5\n2"),
                       "2\n9.5\n10")
    }

    func testSortLinesDecimalDescendingComparesByValue() {
        XCTAssertEqual(LineOps.sortLinesDecimalDescending("10.234\n9.876\n2.5"),
                       "10.234\n9.876\n2.5")
    }

    func testDecimalSortKeepsNonNumericLinesAtTheEndInRelativeOrder() {
        let input = "apple\n3.5\nbanana\n1.25"
        XCTAssertEqual(LineOps.sortLinesDecimalAscending(input), "1.25\n3.5\napple\nbanana")
        XCTAssertEqual(LineOps.sortLinesDecimalDescending(input), "3.5\n1.25\napple\nbanana")
    }

    // MARK: - Duplicate and empty line removal

    func testRemoveConsecutiveDuplicateLinesKeepsFirstOfEachRun() {
        XCTAssertEqual(LineOps.removeConsecutiveDuplicateLines("a\na\nb\nb\na\nc\nc"),
                       "a\nb\na\nc")
    }

    func testRemoveConsecutiveDuplicateLinesKeepsNonAdjacentDuplicates() {
        let input = "a\nb\na"
        XCTAssertEqual(LineOps.removeConsecutiveDuplicateLines(input), input)
        XCTAssertEqual(LineOps.removeDuplicates(input), "a\nb")
    }

    func testRemoveEmptyLinesWithWhitespaceRemovesBlankAndWhitespaceOnlyLines() {
        let input = "a\n\nb\n \n\t\nc\n  \t  \nd"
        XCTAssertEqual(LineOps.removeEmptyLinesWithWhitespace(input), "a\nb\nc\nd")
    }

    // MARK: - Trim operations

    func testTrimTrailingSpaceKeepsLeadingSpaceAndEmptyLines() {
        XCTAssertEqual(LineOps.trimTrailingSpace("  hello  \n\tworld\t\n\n  "),
                       "  hello\n\tworld\n\n")
    }

    func testTrimLeadingSpaceKeepsTrailingSpaceAndEmptyLines() {
        XCTAssertEqual(LineOps.trimLeadingSpace("  hello  \n\tworld\t\n\n  "),
                       "hello  \nworld\t\n\n")
    }

    func testTrimLeadingAndTrailingSpaceKeepsEmptyLines() {
        XCTAssertEqual(LineOps.trimLeadingAndTrailingSpace("  hello  \n\tworld\t\n\n  "),
                       "hello\nworld\n\n")
    }

    func testTrimOpsNeverRemoveLines() {
        let input = "a\n\nb"
        XCTAssertEqual(LineOps.trimTrailingSpace(input), input)
        XCTAssertEqual(LineOps.trimLeadingSpace(input), input)
        XCTAssertEqual(LineOps.trimLeadingAndTrailingSpace(input), input)
    }

    // MARK: - Registry wiring

    func testNewLineOpsAreRegisteredWithNPlusPlusTitles() {
        let commands = Dictionary(uniqueKeysWithValues:
            CommandRegistry.default.lineOpCommands.map { ($0.identifier, $0.title) })
        XCTAssertEqual(commands["reverse-line-order"], "Reverse Line Order")
        XCTAssertEqual(commands["sort-lines-integer-ascending"], "Sort Lines as Integers Ascending")
        XCTAssertEqual(commands["sort-lines-integer-descending"], "Sort Lines as Integers Descending")
        XCTAssertEqual(commands["sort-lines-decimal-ascending"], "Sort Lines as Decimal Numbers Ascending (Dot)")
        XCTAssertEqual(commands["sort-lines-decimal-descending"], "Sort Lines as Decimal Numbers Descending (Dot)")
        XCTAssertEqual(commands["remove-consecutive-duplicate-lines"], "Remove Consecutive Duplicate Lines")
        XCTAssertEqual(commands["remove-empty-lines-with-whitespace"],
                       "Remove empty lines (Containing Blank characters)")
        XCTAssertEqual(commands["trim-trailing-space"], "Trim Trailing Space")
        XCTAssertEqual(commands["trim-leading-space"], "Trim Leading Space")
        XCTAssertEqual(commands["trim-leading-and-trailing-space"], "Trim Leading and Trailing Spaces")
    }

    func testNewLineOpsExecuteThroughTheRegistry() {
        let registry = CommandRegistry.default
        let caret = NSRange(location: 0, length: 0)
        XCTAssertEqual(registry.execute("sort-lines-integer-ascending", text: "10\n2", selection: caret)?.text,
                       "2\n10")
        XCTAssertEqual(registry.execute("sort-lines-decimal-descending", text: "2.5\n10.25", selection: caret)?.text,
                       "10.25\n2.5")
        XCTAssertEqual(registry.execute("remove-consecutive-duplicate-lines", text: "a\na\nb", selection: caret)?.text,
                       "a\nb")
        XCTAssertEqual(registry.execute("remove-empty-lines-with-whitespace", text: "a\n \nb", selection: caret)?.text,
                       "a\nb")
        XCTAssertEqual(registry.execute("trim-trailing-space", text: "a  \nb\t", selection: caret)?.text,
                       "a\nb")
        XCTAssertEqual(registry.execute("trim-leading-space", text: "  a\n\tb", selection: caret)?.text,
                       "a\nb")
        XCTAssertEqual(registry.execute("trim-leading-and-trailing-space", text: "  a  \n\tb\t", selection: caret)?.text,
                       "a\nb")
        XCTAssertEqual(registry.execute("reverse-line-order", text: "a\nb\nc", selection: caret)?.text,
                       "c\nb\na")
    }

    func testNewLineOpsTransformOnlyTheSelection() {
        let result = CommandRegistry.default.execute("trim-trailing-space",
                                                     text: "a  \nb  \nc  ",
                                                     selection: NSRange(location: 0, length: 8))
        XCTAssertEqual(result?.text, "a\nb\nc  ")
        XCTAssertEqual(result?.selection, NSRange(location: 0, length: 4))
    }
}
