import XCTest
@testable import HexpadKit

final class EmbeddedLanguageTests: XCTestCase {

    // MARK: - Helpers

    private func tokens(_ source: String, language: Language) -> [Token] {
        SyntaxTokenizer.tokenize(source, language: language)
    }

    private func contains(_ tokens: [Token], type: TokenType, text: String) -> Bool {
        tokens.contains { $0.type == type && $0.text.contains(text) }
    }

    /// Embedded tokenization must still cover the source exactly once, with
    /// absolute, contiguous, non-overlapping ranges.
    private func assertCoversSource(_ tokens: [Token],
                                    _ source: String,
                                    file: StaticString = #filePath,
                                    line: UInt = #line) {
        XCTAssertEqual(tokens.map(\.text).joined(), source, file: file, line: line)

        var expectedLocation = 0
        for token in tokens {
            XCTAssertEqual(token.range.location, expectedLocation,
                           "tokens must be contiguous", file: file, line: line)
            XCTAssertEqual(token.range.length, (token.text as NSString).length,
                           "token range must match its text", file: file, line: line)
            expectedLocation = NSMaxRange(token.range)
        }
        XCTAssertEqual(expectedLocation, (source as NSString).length,
                       file: file, line: line)
    }

    // MARK: - HTML

    func testHTMLStyleBlockUsesCSSRules() {
        let source = """
        <div class="box">
        <style>
        .card { color: red; margin: 0; }
        </style>
        </div>
        """

        let result = tokens(source, language: .html)
        assertCoversSource(result, source)

        // CSS inside <style>: property and value tokens.
        XCTAssertTrue(contains(result, type: .variable, text: "color"))
        XCTAssertTrue(contains(result, type: .string, text: "red"))
        XCTAssertTrue(contains(result, type: .variable, text: "margin"))

        // Surrounding markup still uses the HTML rules.
        XCTAssertTrue(contains(result, type: .keyword, text: "<div"))
        XCTAssertTrue(contains(result, type: .variable, text: "class"))
    }

    func testHTMLScriptBlockUsesJavaScriptRules() {
        let source = """
        <script>
        const greeting = 'hello';
        function greet() { return greeting; }
        </script>
        """

        let result = tokens(source, language: .html)
        assertCoversSource(result, source)

        // JavaScript inside <script>: keyword and string tokens.
        XCTAssertTrue(contains(result, type: .keyword, text: "const"))
        XCTAssertTrue(contains(result, type: .keyword, text: "return"))
        XCTAssertTrue(contains(result, type: .string, text: "'hello'"))
        XCTAssertTrue(contains(result, type: .function, text: "greet"))
    }

    // MARK: - XML

    func testXMLContainsBothEmbeddedLanguages() {
        let source = """
        <?xml version="1.0"?>
        <root>
        <style>
        body { color: blue; }
        </style>
        <script>
        let answer = "forty-two";
        </script>
        </root>
        """

        let result = tokens(source, language: .xml)
        assertCoversSource(result, source)

        XCTAssertTrue(contains(result, type: .variable, text: "color"))
        XCTAssertTrue(contains(result, type: .string, text: "blue"))
        XCTAssertTrue(contains(result, type: .keyword, text: "let"))
        XCTAssertTrue(contains(result, type: .string, text: "\"forty-two\""))
        XCTAssertTrue(contains(result, type: .keyword, text: "<root"))
    }

    // MARK: - Edge cases

    func testEmptyStyleAndScriptBlocks() {
        let source = "<style></style><script></script>"

        let result = tokens(source, language: .html)
        assertCoversSource(result, source)

        XCTAssertTrue(contains(result, type: .keyword, text: "<style"))
        XCTAssertTrue(contains(result, type: .keyword, text: "<script"))
        XCTAssertFalse(result.isEmpty)
    }

    func testStyleTagInsideHTMLCommentIsNotEmbedded() {
        let source = "<!-- <style>color: red;</style> --><p>text</p>"

        let result = tokens(source, language: .html)
        assertCoversSource(result, source)

        // The whole comment stays a comment; its CSS-looking contents are not
        // tokenized with the CSS rules.
        XCTAssertTrue(contains(result, type: .comment, text: "color: red;"))
        XCTAssertFalse(contains(result, type: .variable, text: "color"))
    }

    func testStyleTagWithQuotedAttributes() {
        let source = #"<style type="text/css" data-close=">" media='screen'>p { color: green; }</style>"#

        let result = tokens(source, language: .html)
        assertCoversSource(result, source)

        XCTAssertTrue(contains(result, type: .keyword, text: "<style"))
        XCTAssertTrue(contains(result, type: .variable, text: "color"))
        XCTAssertTrue(contains(result, type: .string, text: "green"))
    }

    func testScriptWithQuotedAttributeAndMultipleLines() {
        // The quoted attribute value contains a literal closing-tag sequence,
        // which must not end the opening tag or start content early.
        let source = #"""
        <script type="text/javascript" data-marker="</script>">
        function greet(name) {
            const message = "Hello, " + name;
            return message;
        }
        </script>
        """#

        let result = tokens(source, language: .html)
        assertCoversSource(result, source)

        XCTAssertTrue(contains(result, type: .keyword, text: "const"))
        XCTAssertTrue(contains(result, type: .keyword, text: "return"))
        XCTAssertTrue(contains(result, type: .string, text: "\"Hello, \""))
        XCTAssertTrue(contains(result, type: .function, text: "greet"))
    }

    // MARK: - Parity

    func testPlainHTMLMarkupMatchesRawRuleTable() {
        let source = #"<div id="main" class="box">Hello &amp; welcome</div>"#
        let length = (source as NSString).length

        let embeddedPath = SyntaxTokenizer.tokenize(source, language: .html)
        let baseline = SyntaxTokenizer.tokenize(
            source,
            rules: SyntaxTokenizer.compiledRules(for: .html),
            in: NSRange(location: 0, length: length)
        )

        XCTAssertEqual(embeddedPath.map(\.type), baseline.map(\.type))
        XCTAssertEqual(embeddedPath.map(\.text), baseline.map(\.text))
        XCTAssertEqual(embeddedPath.map(\.range.location), baseline.map(\.range.location))
        XCTAssertEqual(embeddedPath.map(\.range.length), baseline.map(\.range.length))
    }

    func testPlainXMLMarkupMatchesRawRuleTable() {
        let source = #"<root id="main"><child>text &amp; more</child></root>"#
        let length = (source as NSString).length

        let embeddedPath = SyntaxTokenizer.tokenize(source, language: .xml)
        let baseline = SyntaxTokenizer.tokenize(
            source,
            rules: SyntaxTokenizer.compiledRules(for: .xml),
            in: NSRange(location: 0, length: length)
        )

        XCTAssertEqual(embeddedPath.map(\.type), baseline.map(\.type))
        XCTAssertEqual(embeddedPath.map(\.text), baseline.map(\.text))
        XCTAssertEqual(embeddedPath.map(\.range.location), baseline.map(\.range.location))
        XCTAssertEqual(embeddedPath.map(\.range.length), baseline.map(\.range.length))
    }
}
