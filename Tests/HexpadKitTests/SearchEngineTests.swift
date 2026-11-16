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

    func testIsValidRegex() {
        XCTAssertTrue(SearchEngine.isValidRegex("a+b"))
        XCTAssertFalse(SearchEngine.isValidRegex("a(b"))
        XCTAssertTrue(SearchEngine.isValidRegex(""))
    }

    // Literal mode must not treat $1 as a template group reference.
    func testLiteralReplaceKeepsDollar() {
        let result = SearchEngine.replace("price 5", pattern: "5", replacement: "$1 dollars", options: [])
        XCTAssertEqual(result, "price $1 dollars")
    }

    // Regex mode must still honour templates.
    func testRegexReplaceUsesTemplates() {
        let result = SearchEngine.replace("ab", pattern: "(a)(b)", replacement: "$2$1", options: [.regex])
        XCTAssertEqual(result, "ba")
    }

    // Backslash in a literal replacement must survive verbatim.
    func testLiteralReplaceKeepsBackslash() {
        let result = SearchEngine.replace("a", pattern: "a", replacement: "\\n", options: [])
        XCTAssertEqual(result, "\\n")
    }

    // searchInFiles must skip binary/oversized files without crashing.
    func testSearchInFilesSkipsLargeFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hexpad-sif-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "needle here".write(to: dir.appendingPathComponent("small.txt"), atomically: true, encoding: .utf8)
        let big = dir.appendingPathComponent("big.txt")
        let filler = String(repeating: "x", count: 2048)
        try filler.write(to: big, atomically: true, encoding: .utf8)

        let hitsSmall = SearchEngine.searchInFiles(directory: dir, pattern: "needle", options: [], maxBytes: 4096)
        XCTAssertEqual(hitsSmall.count, 1)
        let hitsNone = SearchEngine.searchInFiles(directory: dir, pattern: "needle", options: [], maxBytes: 1)
        XCTAssertEqual(hitsNone.count, 0)
    }

    // Notepad++ whole-word applies in regex mode too: foo must not match
    // foobar, foo_bar, or barfoo.
    func testWholeWordWithRegex() {
        let text = "foo foobar foo_bar barfoo foo."
        let matches = SearchEngine.search(text, pattern: "foo", options: [.wholeWord, .regex])
        XCTAssertEqual(matches.count, 2)
        XCTAssertEqual(matches.map(\.text), ["foo", "foo"])
    }

    // ^ and $ anchor at every line boundary (multiline), not just buffer ends.
    func testRegexAnchorsMatchLines() {
        let text = "alpha\nbeta\ngamma\n"
        let matches = SearchEngine.search(text, pattern: "^[a-z]+$", options: [.regex])
        XCTAssertEqual(matches.count, 3)
        XCTAssertEqual(matches.map(\.text), ["alpha", "beta", "gamma"])
    }

    // In-selection search keeps absolute ranges and ignores matches outside the range.
    func testSearchWithinRange() {
        let text = "one two one two"
        let matches = SearchEngine.search(text, pattern: "one", options: [.inSelection],
                                          range: NSRange(location: 8, length: 7))
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].range.location, 8)
        XCTAssertEqual(matches[0].text, "one")
    }

    // Replace-in-selection must leave text before and after the scope untouched.
    func testReplaceWithinRange() {
        let text = "cat dog cat dog"
        let result = SearchEngine.replace(text, pattern: "cat", replacement: "dog",
                                          options: [.inSelection],
                                          range: NSRange(location: 8, length: 7))
        XCTAssertEqual(result, "cat dog dog dog")
    }

    // Replace All in Files rewrites each matching file and reports per-file counts.
    func testReplaceInFilesReportsPerFileCounts() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hexpad-rif-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let first = dir.appendingPathComponent("first.txt")
        let second = dir.appendingPathComponent("second.txt")
        let untouched = dir.appendingPathComponent("untouched.txt")
        try "foo foo".write(to: first, atomically: true, encoding: .utf8)
        try "foo".write(to: second, atomically: true, encoding: .utf8)
        try "bar".write(to: untouched, atomically: true, encoding: .utf8)

        let replaced = SearchEngine.replaceInFiles(directory: dir, pattern: "foo",
                                                   replacement: "baz", options: [])
        let counts = Dictionary(uniqueKeysWithValues: replaced.map { ($0.0.lastPathComponent, $0.1) })

        XCTAssertEqual(replaced.count, 2)
        XCTAssertEqual(counts["first.txt"], 2)
        XCTAssertEqual(counts["second.txt"], 1)
        XCTAssertNil(counts["untouched.txt"])
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "baz baz")
        XCTAssertEqual(try String(contentsOf: second, encoding: .utf8), "baz")
        XCTAssertEqual(try String(contentsOf: untouched, encoding: .utf8), "bar")
    }
}

extension SearchEngineTests {
    func testRepeatedSearchReusesCompiledRegexAndPatternChangeRecaches() {
        SearchEngine.resetRegexCacheForTesting()
        let text = "alpha beta alpha"

        _ = SearchEngine.search(text, pattern: "alpha", options: [])
        XCTAssertEqual(SearchEngine.regexCompileCountForTesting, 1)

        _ = SearchEngine.search(text, pattern: "alpha", options: [])
        XCTAssertEqual(SearchEngine.regexCompileCountForTesting, 1,
                       "same pattern and options must hit the one-entry cache")

        _ = SearchEngine.search(text, pattern: "beta", options: [])
        XCTAssertEqual(SearchEngine.regexCompileCountForTesting, 2,
                       "a pattern change misses and compiles once")

        _ = SearchEngine.search(text, pattern: "beta", options: [])
        XCTAssertEqual(SearchEngine.regexCompileCountForTesting, 2,
                       "the replacement entry is cached too")
    }

    /// R3: Find in Files runs `searchInFiles` on a global queue while the find
    /// bar searches on the main thread. The one-entry regex cache is shared, so
    /// concurrent callers must neither corrupt it nor receive another pattern's
    /// compiled regex.
    func testConcurrentSearchInFilesReturnsCorrectResults() throws {
        SearchEngine.resetRegexCacheForTesting()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hexpad-search-cache-race-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // One distinct pattern per file: a cross-pattern cache mix-up changes
        // the reported results instead of merely compiling twice.
        let patterns = (0..<8).map { "needle\($0)" }
        for (index, pattern) in patterns.enumerated() {
            let url = directory.appendingPathComponent("file\(index).txt")
            try "\(pattern) \(pattern)\n".write(to: url, atomically: true, encoding: .utf8)
        }

        let failureLock = NSLock()
        var failures: [String] = []
        DispatchQueue.concurrentPerform(iterations: 64) { iteration in
            let pattern = patterns[iteration % patterns.count]
            let hits = SearchEngine.searchInFiles(directory: directory,
                                                  pattern: pattern,
                                                  options: [.regex, .caseSensitive])
            let matchCount = hits.reduce(0) { $0 + $1.1.count }
            if hits.count != 1 || matchCount != 2 {
                failureLock.lock()
                failures.append("\(pattern): \(hits.count) file(s), \(matchCount) match(es)")
                failureLock.unlock()
            }
        }

        XCTAssertEqual(failures, [], "a concurrent search used the wrong compiled pattern")
        XCTAssertGreaterThan(SearchEngine.regexCompileCountForTesting, 0,
                             "the shared cache still compiles")
    }
}
