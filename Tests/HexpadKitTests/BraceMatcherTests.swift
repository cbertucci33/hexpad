import XCTest
@testable import HexpadKit

/// Pure-logic coverage for `BraceMatcher`: caret adjacency, depth across the
/// same pair type, both directions, multi-char pairs and the nil paths.
final class BraceMatcherTests: XCTestCase {

    private let swiftBrackets = LexerDefinition.swift.brackets

    private func match(_ text: String,
                       _ caret: Int,
                       brackets: [LexerDefinition.BracketPair]? = nil) -> BraceMatcher.Match? {
        BraceMatcher.matchDetail(text: text,
                                 caret: caret,
                                 brackets: brackets ?? swiftBrackets)
    }

    /// A hand-built definition carrying a multi-character opener and closer.
    private let angleBrackets = [
        LexerDefinition.BracketPair(open: "<%", close: "%>")
    ]

    // MARK: - Every Swift bracket type, both directions

    func testCurlyBraceMatchesAfterOpenAndBeforeClose() throws {
        let text = "{ body }" // 0 '{' ... 7 '}'

        let afterOpen = try XCTUnwrap(match(text, 1))
        XCTAssertEqual(afterOpen.matchedBracket, NSRange(location: 7, length: 1))
        XCTAssertEqual(afterOpen.caretBracket, NSRange(location: 0, length: 1))
        XCTAssertTrue(afterOpen.caretIsOpen)
        XCTAssertEqual(afterOpen.innerRange, NSRange(location: 1, length: 6))

        let beforeClose = try XCTUnwrap(match(text, 7))
        XCTAssertEqual(beforeClose.matchedBracket, NSRange(location: 0, length: 1))
        XCTAssertEqual(beforeClose.caretBracket, NSRange(location: 7, length: 1))
        XCTAssertFalse(beforeClose.caretIsOpen)
        XCTAssertEqual(beforeClose.innerRange, NSRange(location: 1, length: 6))
    }

    func testSquareBracketMatchesBothDirections() {
        let text = "[a[b]c]" // 0 '[' 2 '[' 4 ']' 6 ']'

        XCTAssertEqual(match(text, 1)?.matchedBracket, NSRange(location: 6, length: 1))
        XCTAssertEqual(match(text, 3)?.matchedBracket, NSRange(location: 4, length: 1))
        XCTAssertEqual(match(text, 6)?.matchedBracket, NSRange(location: 0, length: 1))
    }

    func testParenthesisMatchesBothDirections() {
        let text = "(x(y)z)" // 0 '(' 2 '(' 4 ')' 6 ')'

        XCTAssertEqual(match(text, 1)?.matchedBracket, NSRange(location: 6, length: 1))
        XCTAssertEqual(match(text, 3)?.matchedBracket, NSRange(location: 4, length: 1))
        XCTAssertEqual(match(text, 6)?.matchedBracket, NSRange(location: 0, length: 1))
    }

    // MARK: - Nesting

    func testNestedSamePairIncrementsDepth() {
        let text = "{ a { b } c }" // inner open 4, inner close 8, outer close 12

        XCTAssertEqual(match(text, 1)?.matchedBracket, NSRange(location: 12, length: 1),
                       "the outer open skips its nested pair")
        XCTAssertEqual(match(text, 5)?.matchedBracket, NSRange(location: 8, length: 1))
        XCTAssertEqual(match(text, 12)?.matchedBracket, NSRange(location: 0, length: 1),
                       "the outer close skips its nested pair")
    }

    func testOtherPairTypesDoNotChangeDepth() {
        let text = "{ ( ) }" // 0 '{' 2 '(' 4 ')' 6 '}'

        XCTAssertEqual(match(text, 1)?.matchedBracket, NSRange(location: 6, length: 1),
                       "parentheses inside braces do not disturb brace depth")
        XCTAssertEqual(match(text, 3)?.matchedBracket, NSRange(location: 4, length: 1))
    }

    // MARK: - Multi-character pairs

    func testMultiCharPairMatchesByStringInBothDirections() throws {
        let text = "<% hi %>" // open 0..<2, close 6..<8

        let afterOpen = try XCTUnwrap(match(text, 2, brackets: angleBrackets))
        XCTAssertEqual(afterOpen.matchedBracket, NSRange(location: 6, length: 2))
        XCTAssertEqual(afterOpen.innerRange, NSRange(location: 2, length: 4))

        let beforeClose = try XCTUnwrap(match(text, 6, brackets: angleBrackets))
        XCTAssertEqual(beforeClose.matchedBracket, NSRange(location: 0, length: 2))
        XCTAssertFalse(beforeClose.caretIsOpen)
        XCTAssertEqual(beforeClose.innerRange, NSRange(location: 2, length: 4))
    }

    func testMultiCharPairNesting() {
        let text = "<% a <% b %> c %>" // inner open 5, inner close 10, outer close 15

        XCTAssertEqual(match(text, 2, brackets: angleBrackets)?.matchedBracket,
                       NSRange(location: 15, length: 2))
        XCTAssertEqual(match(text, 7, brackets: angleBrackets)?.matchedBracket,
                       NSRange(location: 10, length: 2))
    }

    // MARK: - Nil paths and precedence

    func testCaretNotAdjacentToBracketReturnsNil() {
        XCTAssertNil(match("{ abc }", 3))
        XCTAssertNil(match("no brackets here", 5))
    }

    func testUnmatchedBracketReturnsNil() {
        XCTAssertNil(match("{ abc", 1), "unmatched open")
        XCTAssertNil(match("abc }", 4), "unmatched close")
    }

    func testEmptyDefinitionAndOutOfBoundsCaretReturnNil() {
        XCTAssertNil(match("{ a }", 1, brackets: []))
        XCTAssertNil(match("{ a }", -1))
        XCTAssertNil(match("{ a }", 99))
    }

    func testBracketBeforeCaretTakesPrecedenceOverBracketAfter() throws {
        // At caret 1 the '{' before it wins over the '}' after it.
        let result = try XCTUnwrap(match("{}", 1))
        XCTAssertEqual(result.caretIsOpen, true)
        XCTAssertEqual(result.caretBracket, NSRange(location: 0, length: 1))
    }

    func testMatchConvenienceReturnsMatchedBracketRange() {
        let text = "[value]"
        XCTAssertEqual(BraceMatcher.match(text: text, caret: 1, brackets: swiftBrackets),
                       match(text, 1)?.matchedBracket)
    }
}
