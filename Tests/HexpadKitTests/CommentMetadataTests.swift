import XCTest
@testable import HexpadKit

/// P17f-1: the line-comment toggle's prefix is driven by each language's lexer
/// comment metadata. These tests exercise the same resolver the app calls, with
/// real `DocumentModel`s so the document-language-to-prefix mapping is covered
/// end to end (not just the underlying definition values).
final class CommentMetadataTests: XCTestCase {

    private func document(_ language: String) -> DocumentModel {
        let document = DocumentModel(text: "value = 1")
        document.setLanguage(language)
        return document
    }

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

    func testPlainTextDocumentFallsBackToDoubleSlash() {
        let resolved = CommentPrefixResolver.lineCommentPrefix(
            for: document(Language.plain.rawValue)
        )
        XCTAssertEqual(resolved, "//")
    }

    func testUnknownLanguageFallsBackToDoubleSlash() {
        let resolved = CommentPrefixResolver.lineCommentPrefix(
            for: document("Not A Language")
        )
        XCTAssertEqual(resolved, "//")
    }

    func testNilDocumentFallsBackToDoubleSlash() {
        XCTAssertEqual(CommentPrefixResolver.lineCommentPrefix(for: nil), "//")
    }

    /// A language with block comments but no line prefix (HTML, CSS, Markdown,
    /// XML, OCaml) must fall back instead of handing an empty prefix to
    /// `LineOps`, which would make the toggle a no-op.
    func testBlockOnlyLanguageFallsBackToDoubleSlash() throws {
        let html = try XCTUnwrap(LexerDefinitions.definition(for: .html))
        XCTAssertNil(html.comments?.linePrefix)

        let resolved = CommentPrefixResolver.lineCommentPrefix(
            for: document(Language.html.rawValue)
        )
        XCTAssertEqual(resolved, "//")
    }
}
