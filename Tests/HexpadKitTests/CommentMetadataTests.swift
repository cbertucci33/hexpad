import XCTest
@testable import HexpadKit

/// P17f: the comment toggles' tokens are driven by each language's lexer
/// comment metadata. These tests exercise the same resolver the app calls, with
/// real `DocumentModel`s so the document-language-to-token mapping is covered
/// end to end (not just the underlying definition values).
///
/// A language without the matching metadata returns `nil`; the app disables
/// that menu item rather than guessing a C-family token.
final class CommentMetadataTests: XCTestCase {

    private func document(_ language: String) -> DocumentModel {
        let document = DocumentModel(text: "value = 1")
        document.setLanguage(language)
        return document
    }

    // MARK: - Line comments

    func testSwiftDocumentUsesDoubleSlash() {
        let resolved = CommentPrefixResolver.lineCommentPrefix(
            for: document(Language.swift.rawValue)
        )
        XCTAssertEqual(resolved, "//")
    }

    func testPythonDocumentUsesHash() {
        let resolved = CommentPrefixResolver.lineCommentPrefix(
            for: document(Language.python.rawValue)
        )
        XCTAssertEqual(resolved, "#")
    }

    func testPascalDocumentUsesItsDeclaredLinePrefix() throws {
        let definition = try XCTUnwrap(LexerDefinitions.definition(for: .pascal))
        let comments = try XCTUnwrap(definition.comments)

        // Read what Pascal actually declares: `(* *)` is its one block-comment
        // pair (the highlighter also knows `{ }`), and `//` is its line prefix.
        XCTAssertEqual(comments.linePrefix, "//")
        XCTAssertEqual(comments.blockStart, "(*")
        XCTAssertEqual(comments.blockEnd, "*)")

        let resolved = CommentPrefixResolver.lineCommentPrefix(
            for: document(Language.pascal.rawValue)
        )
        XCTAssertEqual(resolved, comments.linePrefix)
    }

    func testPlainTextDocumentHasNoLineComment() {
        XCTAssertNil(CommentPrefixResolver.lineCommentPrefix(
            for: document(Language.plain.rawValue)
        ))
    }

    func testUnknownLanguageHasNoLineComment() {
        XCTAssertNil(CommentPrefixResolver.lineCommentPrefix(
            for: document("Not A Language")
        ))
    }

    func testNilDocumentHasNoLineComment() {
        XCTAssertNil(CommentPrefixResolver.lineCommentPrefix(for: nil))
    }

    /// A language with block comments but no line prefix (HTML, CSS, Markdown,
    /// XML, OCaml) must report no line token instead of handing a guessed `//`
    /// to `LineOps`.
    func testBlockOnlyLanguageHasNoLineComment() throws {
        let html = try XCTUnwrap(LexerDefinitions.definition(for: .html))
        XCTAssertNil(html.comments?.linePrefix)

        XCTAssertNil(CommentPrefixResolver.lineCommentPrefix(
            for: document(Language.html.rawValue)
        ))
    }

    // MARK: - Block comments

    func testBlockDelimitersComeFromLanguageMetadata() throws {
        let html = try XCTUnwrap(CommentPrefixResolver.blockCommentDelimiters(for: .html))
        XCTAssertEqual(html.open, "<!--")
        XCTAssertEqual(html.close, "-->")

        let swift = try XCTUnwrap(CommentPrefixResolver.blockCommentDelimiters(for: .swift))
        XCTAssertEqual(swift.open, "/*")
        XCTAssertEqual(swift.close, "*/")

        let pascal = try XCTUnwrap(CommentPrefixResolver.blockCommentDelimiters(for: .pascal))
        XCTAssertEqual(pascal.open, "(*")
        XCTAssertEqual(pascal.close, "*)")
    }

    func testBlockDelimitersResolveThroughDocumentLanguage() throws {
        let html = try XCTUnwrap(CommentPrefixResolver.blockCommentDelimiters(
            for: document(Language.html.rawValue)
        ))
        XCTAssertEqual(html.open, "<!--")
        XCTAssertEqual(html.close, "-->")
    }

    func testLanguagesWithoutBlockPairHaveNoBlockDelimiters() {
        XCTAssertNil(CommentPrefixResolver.blockCommentDelimiters(for: .python))
        XCTAssertNil(CommentPrefixResolver.blockCommentDelimiters(for: .shell))
        XCTAssertNil(CommentPrefixResolver.blockCommentDelimiters(for: .plain))
        XCTAssertNil(CommentPrefixResolver.blockCommentDelimiters(for: nil))
        XCTAssertNil(CommentPrefixResolver.blockCommentDelimiters(for: document("Not A Language")))
    }

    func testBlockCommentParameterEncodesThePair() {
        XCTAssertEqual(CommentPrefixResolver.blockCommentParameter(
            for: document(Language.html.rawValue)
        ), "<!-- -->")
        XCTAssertNil(CommentPrefixResolver.blockCommentParameter(
            for: document(Language.python.rawValue)
        ))
    }
}
