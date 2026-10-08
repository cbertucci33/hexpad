import XCTest
@testable import HexpadKit

final class LineOpsTests: XCTestCase {
    func testSortAscending() {
        let input = "banana\napple\ncherry"
        let result = LineOps.sortAscending(input)
        XCTAssertEqual(result, "apple\nbanana\ncherry")
    }
    
    func testSortDescending() {
        let input = "apple\nbanana\ncherry"
        let result = LineOps.sortDescending(input)
        XCTAssertEqual(result, "cherry\nbanana\napple")
    }
    
    func testRemoveDuplicates() {
        let input = "apple\nbanana\napple\ncherry\nbanana"
        let result = LineOps.removeDuplicates(input)
        XCTAssertEqual(result, "apple\nbanana\ncherry")
    }
    
    func testRemoveBlankLines() {
        let input = "apple\n\nbanana\n\ncherry"
        let result = LineOps.removeBlankLines(input)
        XCTAssertEqual(result, "apple\nbanana\ncherry")
    }
    
    func testJoinLines() {
        let input = "apple\nbanana\ncherry"
        let result = LineOps.joinLines(input)
        XCTAssertEqual(result, "apple banana cherry")
    }
    
    func testReverseLines() {
        let input = "one\ntwo\nthree"
        let result = LineOps.reverseLines(input)
        XCTAssertEqual(result, "three\ntwo\none")
    }
    
    func testTrimLeading() {
        let input = "  hello\n  world"
        let result = LineOps.trimLeading(input)
        XCTAssertEqual(result, "hello\nworld")
    }
    
    func testTrimTrailing() {
        let input = "hello  \nworld  "
        let result = LineOps.trimTrailing(input)
        XCTAssertEqual(result, "hello\nworld")
    }
    
    func testTrimAll() {
        let input = "  hello  \n  world  "
        let result = LineOps.trimAll(input)
        XCTAssertEqual(result, "hello\nworld")
    }
    
    func testIndent() {
        let input = "hello\nworld"
        let result = LineOps.indent(input, by: 4)
        XCTAssertEqual(result, "    hello\n    world")
    }
    
    func testDedent() {
        let input = "    hello\n    world"
        let result = LineOps.dedent(input, by: 4)
        XCTAssertEqual(result, "hello\nworld")
    }
    
    func testSplitLines() {
        let input = "hello,world,test"
        let result = LineOps.splitLines(input, delimiter: ",")
        XCTAssertEqual(result, "hello\nworld\ntest")
    }
}
