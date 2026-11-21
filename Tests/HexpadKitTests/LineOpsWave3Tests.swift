import XCTest
@testable import HexpadKit

/// Wave 3A: block comments, Remove Non-Bookmarked Lines and the rest of the
/// N++ Blank Operations group. Everything is exercised through the pure Kit
/// path — no editor, no pasteboard — so the transforms stay independently
/// verifiable.
final class LineOpsWave3Tests: XCTestCase {

    private let caret = NSRange(location: 0, length: 0)

    // MARK: - Block comment

    func testBlockCommentWrapsAndUnwrapsSingleLine() {
        let first = LineOps.toggleBlockComment("abc", selection: NSRange(location: 0, length: 0))
        XCTAssertEqual(first.text, "/*abc*/")
        XCTAssertEqual(first.selection, NSRange(location: 2, length: 0))

        let second = LineOps.toggleBlockComment(first.text, selection: first.selection)
        XCTAssertEqual(second.text, "abc")
        XCTAssertEqual(second.selection, caret)
    }

    func testBlockCommentPlacesDelimitersOnFirstAndLastNonBlankLines() {
        let text = "  alpha\n  beta  "
        let result = LineOps.toggleBlockComment(text,
                                                 selection: NSRange(location: 0, length: text.utf16.count))
        XCTAssertEqual(result.text, "  /*alpha\n  beta  */")

        let restored = LineOps.toggleBlockComment(result.text,
                                                   selection: NSRange(location: 0,
                                                                      length: result.text.utf16.count))
        XCTAssertEqual(restored.text, text)
    }

    func testBlockCommentLeavesOnlyNestedPairIntactWhenUncommenting() {
        let text = "/* outer /* inner */ still */"
        let result = LineOps.toggleBlockComment(text,
                                                 selection: NSRange(location: 0, length: text.utf16.count))
        XCTAssertEqual(result.text, " outer /* inner */ still ")
    }

    func testBlockCommentOnEmptyOrBlankDocumentIsNoOp() {
        let empty = LineOps.toggleBlockComment("", selection: caret)
        XCTAssertEqual(empty.text, "")
        XCTAssertEqual(empty.selection, caret)

        let blank = LineOps.toggleBlockComment("  \n\t",
                                                selection: NSRange(location: 0, length: 4))
        XCTAssertEqual(blank.text, "  \n\t")
    }

    func testBlockCommentRegistryCommandAcceptsLanguageDelimitersAsParameter() {
        let registry = CommandRegistry.default
        XCTAssertEqual(registry.execute("toggle-block-comment", text: "abc", selection: caret)?.text,
                       "/*abc*/")
        XCTAssertEqual(registry.execute("toggle-block-comment",
                                        parameter: "<!-- -->",
                                        text: "abc",
                                        selection: caret)?.text,
                       "<!--abc-->")
        XCTAssertEqual(registry.execute("toggle-block-comment",
                                        parameter: "(* *)",
                                        text: "abc",
                                        selection: caret)?.text,
                       "(*abc*)")
    }

    // MARK: - Remove Non-Bookmarked Lines

    func testRemoveNonBookmarkedKeepsOnlyMarkedLines() {
        let lines = ["a", "b", "c", "d", "e"]
        XCTAssertEqual(LineOps.removeNonBookmarkedLines(lines, bookmarkedLines: [2, 4]),
                       ["b", "d"])
        XCTAssertEqual(LineOps.removeNonBookmarkedLines("a\nb\nc\nd\ne", bookmarkedLines: [2, 4]),
                       "b\nd")
    }

    func testRemoveNonBookmarkedHandlesAllAndNoneBookmarked() {
        let lines = ["a", "b", "c"]
        XCTAssertEqual(LineOps.removeNonBookmarkedLines(lines, bookmarkedLines: [1, 2, 3]),
                       lines, "all bookmarked keeps every line")
        XCTAssertEqual(LineOps.removeNonBookmarkedLines(lines, bookmarkedLines: []),
                       [], "none bookmarked leaves an empty document")
        XCTAssertEqual(LineOps.removeNonBookmarkedLines("", bookmarkedLines: []), "")
    }

    func testRemoveNonBookmarkedCommandRemapsBookmarksAndKeepsNotes() throws {
        var bookmarks = BookmarkState()
        bookmarks.add(Bookmark(line: 1, note: "first"))
        bookmarks.add(Bookmark(line: 3, note: "third"))
        let state = DocumentState(text: "a\nb\nc",
                                  selection: NSRange(location: 4, length: 0),
                                  bookmarkState: bookmarks)

        let result = try XCTUnwrap(CommandRegistry.default.execute("remove-non-bookmarked-lines",
                                                                   on: state))
        XCTAssertEqual(result.text, "a\nc")
        XCTAssertEqual(result.bookmarkState.lines, [1, 2])
        XCTAssertEqual(result.bookmarkState.note(forLine: 1), "first")
        XCTAssertEqual(result.bookmarkState.note(forLine: 2), "third")
        XCTAssertEqual(result.selection, NSRange(location: 2, length: 0))
    }

    func testRemoveNonBookmarkedCommandNoOpsWhenAllLinesAreBookmarked() throws {
        let bookmarks = BookmarkState(bookmarks: [Bookmark(line: 1), Bookmark(line: 2)])
        let state = DocumentState(text: "a\nb",
                                  selection: NSRange(location: 1, length: 0),
                                  bookmarkState: bookmarks)
        let result = try XCTUnwrap(CommandRegistry.default.execute("remove-non-bookmarked-lines",
                                                                   on: state))
        XCTAssertEqual(result.text, "a\nb")
        XCTAssertEqual(result.bookmarkState.lines, [1, 2])
        XCTAssertEqual(result.selection, NSRange(location: 1, length: 0))
    }

    func testRemoveNonBookmarkedCommandEmptiesDocumentWhenNoneBookmarked() throws {
        let state = DocumentState(text: "a\nb", selection: caret)
        let result = try XCTUnwrap(CommandRegistry.default.execute("remove-non-bookmarked-lines",
                                                                   on: state))
        XCTAssertEqual(result.text, "")
        XCTAssertTrue(result.bookmarkState.isEmpty)
        XCTAssertEqual(result.selection, caret)
    }

    // MARK: - Blank Operations remainder

    func testOpenLinesInsertsABlankLineBetweenLines() {
        XCTAssertEqual(LineOps.openLines("a\nb\nc"), "a\n\nb\n\nc")
        XCTAssertEqual(LineOps.openLines("a"), "a")
        XCTAssertEqual(LineOps.openLines(""), "")
    }

    func testRemoveUnnecessaryBlankLinesCollapsesRunsAndTrimsEdges() {
        XCTAssertEqual(LineOps.removeUnnecessaryBlankLines("a\n\n\nb\n\n\nc\n"), "a\n\nb\n\nc")
        XCTAssertEqual(LineOps.removeUnnecessaryBlankLines(" \na\n \n"), "a")
        XCTAssertEqual(LineOps.removeUnnecessaryBlankLines("\n \n"), "")
    }

    func testEolToWhitespaceFoldsLinesOntoOneLine() {
        XCTAssertEqual(LineOps.eolToWhitespace("a\nb\nc"), "a b c")
        XCTAssertEqual(LineOps.eolToWhitespace("a\nb\n"), "a b ")
        XCTAssertEqual(LineOps.eolToWhitespace("a\nb", replacement: "\t"), "a\tb")
        XCTAssertEqual(LineOps.eolToWhitespace(""), "")
    }

    func testBlankOperationCommandsExecuteThroughTheRegistry() {
        let registry = CommandRegistry.default
        XCTAssertEqual(registry.execute("open-lines", text: "a\nb", selection: caret)?.text,
                       "a\n\nb")
        XCTAssertEqual(registry.execute("remove-unnecessary-blank-lines",
                                        text: "a\n\n\nb", selection: caret)?.text,
                       "a\n\nb")
        XCTAssertEqual(registry.execute("eol-to-space", text: "a\nb", selection: caret)?.text,
                       "a b")
    }

    func testBlankOperationCommandsTransformOnlyTheSelection() {
        let text = "a\n\nb\nc"
        let result = CommandRegistry.default.execute("eol-to-space",
                                                     text: text,
                                                     selection: NSRange(location: 0, length: 2))
        // Only "a\n" is transformed; it becomes "a " and the next line's
        // leading newline is left untouched.
        XCTAssertEqual(result?.text, "a \nb\nc")
        XCTAssertEqual(result?.selection, NSRange(location: 0, length: 2))
    }

    // MARK: - Existing vs. added registration

    func testWave3ACommandsResolveThroughLookupWithoutChangingLegacyGroups() {
        let registry = CommandRegistry.default
        for identifier in ["toggle-block-comment",
                           "remove-non-bookmarked-lines",
                           "open-lines", "remove-unnecessary-blank-lines", "eol-to-space"] {
            XCTAssertNotNil(registry.command(for: identifier), identifier)
            XCTAssertFalse(registry.allCommands.contains { $0.identifier == identifier },
                           "\(identifier) stays outside the pinned legacy groups")
        }
        for identifier in ["remove-blank-lines", "trim-leading-space", "trim-trailing-space",
                           "trim-leading-and-trailing-space", "remove-empty-lines-with-whitespace",
                           "bookmark-remove-lines"] {
            XCTAssertNotNil(registry.command(for: identifier), "pre-existing \(identifier)")
        }
    }
}
