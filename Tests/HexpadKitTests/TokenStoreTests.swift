import XCTest
@testable import HexpadKit

/// Coverage for the viewport-limited and incremental token cache.
final class TokenStoreTests: XCTestCase {

    func testViewportTokenizeReturnsAbsoluteRangesOnly() {
        let text = "def alpha():\n    return 1\n\ndef beta():\n    return 2\n"
        let nsText = text as NSString
        let firstLine = nsText.lineRange(for: NSRange(location: 0, length: 0))

        let tokens = SyntaxTokenizer.tokenize(text, language: .python, in: firstLine)

        XCTAssertFalse(tokens.isEmpty)
        for token in tokens {
            XCTAssertGreaterThanOrEqual(token.range.location, firstLine.location)
            XCTAssertLessThanOrEqual(NSMaxRange(token.range), NSMaxRange(firstLine))
        }
        XCTAssertTrue(tokens.contains { $0.type == .keyword && $0.text == "def" })
    }

    func testIncrementalUpdateMergesEditedLineOnly() {
        var text = "def alpha():\n    return 1\n\ndef beta():\n    return 2\n"
        let store = TokenStore(language: .python)
        let fullRange = NSRange(location: 0, length: (text as NSString).length)
        store.ensureTokens(for: text, range: fullRange)

        let oldLine = (text as NSString).range(of: "    return 2")
        let replacement = "    # note"
        text = (text as NSString).replacingCharacters(in: oldLine, with: replacement)

        store.update(text: text,
                     language: .python,
                     editedRange: NSRange(location: oldLine.location,
                                          length: (replacement as NSString).length))
        store.ensureTokens(for: text,
                           range: NSRange(location: 0, length: (text as NSString).length))

        XCTAssertTrue(store.tokens.contains { $0.type == .comment })
        XCTAssertFalse(store.tokens.contains { $0.type == .number && $0.text == "2" })
        XCTAssertTrue(store.tokens.contains { $0.type == .string || $0.type == .keyword })
    }

    func testEditAtTopKeepsTokensBeforeEditedLine() {
        var text = "def alpha():\n    return 1\n\ndef beta():\n    return 2\n"
        let store = TokenStore(language: .python)
        let fullRange = NSRange(location: 0, length: (text as NSString).length)
        store.ensureTokens(for: text, range: fullRange)

        let editLocation = (text as NSString).range(of: "beta").location
        let editedLineStart = (text as NSString).lineRange(for: NSRange(location: editLocation, length: 0)).location
        let beforeEdit = store.tokens(in: NSRange(location: 0, length: editedLineStart))
        let beforeCount = beforeEdit.count
        XCTAssertGreaterThan(beforeCount, 0)

        text = (text as NSString).replacingCharacters(in: NSRange(location: editLocation, length: 0),
                                                       with: "my_")
        store.update(text: text,
                     language: .python,
                     editedRange: NSRange(location: editLocation, length: 3))

        // Tokens on lines before the edited line are still cached; only the
        // edited band onward was dropped.
        let retained = store.tokens(in: NSRange(location: 0, length: editedLineStart))
        XCTAssertEqual(retained.count, beforeCount)
        XCTAssertEqual(retained.map(\.type), beforeEdit.map(\.type))
    }

    func testLargeFileKeepsViewportOnly() {
        let text = String(repeating: "x = 1\n", count: 180_000)
        XCTAssertGreaterThan((text as NSString).length, TokenStore.largeFileThreshold)

        let store = TokenStore(language: .python)
        let viewport = NSRange(location: 500_000, length: 200)
        let target = store.ensureTokens(for: text, range: viewport)

        XCTAssertTrue(store.isLargeFile)
        XCTAssertLessThan(target.length, 20_000)
        XCTAssertTrue(store.tokens.allSatisfy {
            $0.range.location >= target.location && NSMaxRange($0.range) <= NSMaxRange(target)
        })
    }

    func testPlainLanguageProducesNoTokens() {
        let store = TokenStore(language: .plain)
        let target = store.ensureTokens(for: "plain text", range: NSRange(location: 0, length: 10))
        XCTAssertEqual(target, NSRange(location: 0, length: 10))
        XCTAssertTrue(store.tokens.isEmpty)
    }
}
