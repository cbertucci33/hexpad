import XCTest
@testable import HexpadKit

final class SearchEngineTests: XCTestCase {
    func testSimpleSearch() {
        let text = "hello world hello"
        let matches = SearchEngine.search(text, pattern: "hello", options: [])
        XCTAssertEqual(matches.count, 2)
        XCTAssertEqual(matches[0].text, "hello")
        XCTAssertEqual(matches[1].text, "hello")
    }
    
    func testCaseInsensitive() {
        let text = "Hello WORLD hello"
        let matches = SearchEngine.search(text, pattern: "hello", options: [])
        XCTAssertEqual(matches.count, 2)
    }
    
    func testCaseSensitive() {
        let text = "Hello WORLD hello"
        let matches = SearchEngine.search(text, pattern: "hello", options: [.caseSensitive])
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].text, "hello")
    }
    
    func testWholeWord() {
        let text = "hello help hero"
        let matches = SearchEngine.search(text, pattern: "hello", options: [.wholeWord])
        XCTAssertEqual(matches.count, 1)
    }
    
    func testRegexSearch() {
        let text = "abc123 def456 ghi789"
        let matches = SearchEngine.search(text, pattern: "\\d+", options: [.regex])
        XCTAssertEqual(matches.count, 3)
    }
    
    func testReplace() {
        let text = "hello world hello"
        let result = SearchEngine.replace(text, pattern: "hello", replacement: "hi", options: [])
        XCTAssertEqual(result, "hi world hi")
    }
    
    func testReplaceAllCaseSensitive() {
        let text = "Hello hello HELLO"
        let result = SearchEngine.replace(text, pattern: "hello", replacement: "hi", options: [.caseSensitive])
        XCTAssertEqual(result, "Hello hi HELLO")
    }
    
    func testEmptyPattern() {
        let text = "hello"
        let matches = SearchEngine.search(text, pattern: "", options: [])
        XCTAssertTrue(matches.isEmpty)
        
        let result = SearchEngine.replace(text, pattern: "", replacement: "x", options: [])
        XCTAssertEqual(result, "hello")
    }
    
    func testNoMatches() {
        let text = "hello world"
        let matches = SearchEngine.search(text, pattern: "xyz", options: [])
        XCTAssertTrue(matches.isEmpty)
    }
    
    func testInvalidRegexFallback() {
        let text = "hello world"
        let matches = SearchEngine.search(text, pattern: "[invalid", options: [.regex])
        // Should not crash, returns empty or falls back
        XCTAssert(matches.count >= 0)
    }
    
    // Single-range replace: only the given range is substituted.
    func testReplaceRangeOnlyCurrentMatch() {
        let text = "hello world hello"
        // Replace the first "hello" (range 0..<5).
        let result = SearchEngine.replaceRange(in: text, replacement: "hi", range: NSRange(location: 0, length: 5))
        XCTAssertEqual(result, "hi world hello")
    }
    
    func testReplaceRangeMiddleOfText() {
        let text = "cat dog cat"
        // "dog" sits at 4..<7.
        let result = SearchEngine.replaceRange(in: text, replacement: "cat", range: NSRange(location: 4, length: 3))
        XCTAssertEqual(result, "cat cat cat")
    }
    
    // Emoji code units: length must be measured in NSString (UTF-16) units, not Swift chars.
    func testReplaceRangeAfterEmoji() {
        let text = "a😀b hello c hello"
        // First "hello" starts after "a😀b" = 4 UTF-16 units (a, 😀 is a surrogate pair, b, space).
        let ns = text as NSString
        let helloRange = ns.range(of: "hello")
        let result = SearchEngine.replaceRange(in: text, replacement: "hi", range: helloRange)
        XCTAssertEqual(result, "a😀b hi c hello")
    }
    
    // A stale/over-long range is clamped to the text, never crashes.
    func testReplaceRangeClampsOutOfRange() {
        let text = "hello"
        let result = SearchEngine.replaceRange(in: text, replacement: "X", range: NSRange(location: 2, length: 100))
        XCTAssertEqual(result, "heX")
    }
    
    // A zero-length or not-found range returns the text unchanged.
    func testReplaceRangeZeroLength() {
        let text = "hello"
        let result = SearchEngine.replaceRange(in: text, replacement: "X", range: NSRange(location: 2, length: 0))
        XCTAssertEqual(result, "hello")
    }
    
    // The search term appears AFTER an emoji; the tail occurrence must be replaced.
    func testReplaceAfterEmoji() {
        let text = "a😀b hello c hello"
        let result = SearchEngine.replace(text, pattern: "hello", replacement: "hi", options: [])
        XCTAssertEqual(result, "a😀b hi c hi")
    }
}
