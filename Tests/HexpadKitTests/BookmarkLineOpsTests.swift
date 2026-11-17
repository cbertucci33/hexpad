import XCTest
@testable import HexpadKit

/// Whole-line operations driven by bookmarks: Copy, Cut, Paste-to-Replace,
/// Remove and Inverse. The buffer is LF-only, so every expected string uses
/// `"\n"` regardless of a document's save EOL.
final class BookmarkLineOpsTests: XCTestCase {

    private func state(_ text: String,
                       selection: NSRange = NSRange(location: 0, length: 0),
                       bookmarks: [Int] = []) -> BookmarkState {
        BookmarkState(bookmarks: bookmarks.map { Bookmark(line: $0) })
    }

    // MARK: - Copy

    func testCopyCollectsBookmarkedLinesInDocumentOrder() {
        let text = "a\nb\nc\nd"
        let result = BookmarkLineOps.copy(text,
                                          selection: NSRange(location: 3, length: 0),
                                          bookmarks: state(text, bookmarks: [4, 2]))

        XCTAssertEqual(result.clipboardText, "b\nd\n")
        XCTAssertEqual(result.text, text)
        XCTAssertEqual(result.selection, NSRange(location: 3, length: 0))
        XCTAssertEqual(result.bookmarks.lines, [2, 4])
    }

    func testCopyWithoutBookmarksLeavesClipboardUntouched() {
        let result = BookmarkLineOps.copy("a\nb", selection: NSRange(location: 0, length: 0),
                                          bookmarks: BookmarkState())
        XCTAssertEqual(result.text, "a\nb")
        XCTAssertNil(result.clipboardText)
    }

    func testCopyTerminatesEveryLineIncludingTheLast() {
        let result = BookmarkLineOps.copy("only", selection: NSRange(location: 0, length: 0),
                                          bookmarks: state("only", bookmarks: [1]))
        XCTAssertEqual(result.clipboardText, "only\n")
    }

    // MARK: - Cut

    func testCutRemovesBookmarkedLinesAndClearsTheirBookmarks() {
        let text = "a\nb\nc\nd"
        let result = BookmarkLineOps.cut(text,
                                         selection: NSRange(location: 0, length: 0),
                                         bookmarks: state(text, bookmarks: [2, 4]))

        XCTAssertEqual(result.text, "a\nc")
        XCTAssertEqual(result.clipboardText, "b\nd\n")
        XCTAssertTrue(result.bookmarks.isEmpty)
    }

    func testCutFinalLineWithoutTerminatorAlsoRemovesThePrecedingBreak() {
        let text = "a\nb\nc"
        let result = BookmarkLineOps.cut(text,
                                         selection: NSRange(location: 0, length: 0),
                                         bookmarks: state(text, bookmarks: [3]))

        XCTAssertEqual(result.text, "a\nb")
        XCTAssertEqual(result.clipboardText, "c\n")
        XCTAssertTrue(result.bookmarks.isEmpty)
    }

    func testCutMergesConsecutiveBookmarkedLinesIntoOneRun() {
        let text = "a\nb\nc"
        let result = BookmarkLineOps.cut(text,
                                         selection: NSRange(location: 0, length: 0),
                                         bookmarks: state(text, bookmarks: [2, 3]))

        XCTAssertEqual(result.text, "a")
        XCTAssertEqual(result.clipboardText, "b\nc\n")
    }

    func testCutMapsSelectionAcrossRemovedLines() {
        let text = "a\nb\nc\nd"
        let result = BookmarkLineOps.cut(text,
                                         selection: NSRange(location: 6, length: 0),
                                         bookmarks: state(text, bookmarks: [2]))

        XCTAssertEqual(result.text, "a\nc\nd")
        XCTAssertEqual(result.selection, NSRange(location: 4, length: 0))
    }

    func testCutWithoutBookmarksIsANoOp() {
        let text = "a\nb"
        let result = BookmarkLineOps.cut(text, selection: NSRange(location: 0, length: 0),
                                         bookmarks: BookmarkState())
        XCTAssertEqual(result.text, text)
        XCTAssertNil(result.clipboardText)
    }

    // MARK: - Remove

    func testRemoveDeletesBookmarkedLinesWithoutClipboard() {
        let text = "one\ntwo\nthree"
        let result = BookmarkLineOps.remove(text,
                                            selection: NSRange(location: 0, length: 0),
                                            bookmarks: state(text, bookmarks: [1, 3]))

        XCTAssertEqual(result.text, "two")
        XCTAssertNil(result.clipboardText)
        XCTAssertTrue(result.bookmarks.isEmpty)
    }

    func testRemoveAllBookmarkedLinesLeavesAnEmptyBuffer() {
        let text = "a\nb"
        let result = BookmarkLineOps.remove(text,
                                            selection: NSRange(location: 3, length: 0),
                                            bookmarks: state(text, bookmarks: [1, 2]))

        XCTAssertEqual(result.text, "")
        XCTAssertEqual(result.selection, NSRange(location: 0, length: 0))
    }

    // MARK: - Paste-to-Replace

    func testPasteReplacesBookmarkedLinesInOrderAndKeepsBookmarks() {
        let text = "a\nb\nc\nd"
        let result = BookmarkLineOps.pasteReplacing(text,
                                                    selection: NSRange(location: 0, length: 0),
                                                    bookmarks: state(text, bookmarks: [2, 4]),
                                                    clipboard: "B\nD\n")

        XCTAssertEqual(result.text, "a\nB\nc\nD")
        XCTAssertEqual(result.bookmarks.lines, [2, 4])
        XCTAssertNil(result.clipboardText)
    }

    func testPasteWithFewerClipboardLinesLeavesExtraBookmarkedLinesAlone() {
        let text = "a\nb\nc\nd"
        let result = BookmarkLineOps.pasteReplacing(text,
                                                    selection: NSRange(location: 0, length: 0),
                                                    bookmarks: state(text, bookmarks: [1, 3, 4]),
                                                    clipboard: "X")

        XCTAssertEqual(result.text, "X\nb\nc\nd")
        XCTAssertEqual(result.bookmarks.lines, [1, 3, 4])
    }

    func testPasteWithMoreClipboardLinesIgnoresTheExtras() {
        let text = "a\nb\nc\nd"
        let result = BookmarkLineOps.pasteReplacing(text,
                                                    selection: NSRange(location: 0, length: 0),
                                                    bookmarks: state(text, bookmarks: [2]),
                                                    clipboard: "X\nY\nZ")

        XCTAssertEqual(result.text, "a\nX\nc\nd")
    }

    func testPasteNormalizesCRLFClipboardToLF() {
        let text = "a\nb"
        let result = BookmarkLineOps.pasteReplacing(text,
                                                    selection: NSRange(location: 0, length: 0),
                                                    bookmarks: state(text, bookmarks: [1, 2]),
                                                    clipboard: "X\r\nY\r\n")

        XCTAssertEqual(result.text, "X\nY")
        XCTAssertEqual(result.bookmarks.lines, [1, 2])
    }

    func testPasteCanReplaceTheTrailingEmptyLine() {
        let text = "a\n"
        let result = BookmarkLineOps.pasteReplacing(text,
                                                    selection: NSRange(location: 2, length: 0),
                                                    bookmarks: state(text, bookmarks: [2]),
                                                    clipboard: "tail")

        XCTAssertEqual(result.text, "a\ntail")
        XCTAssertEqual(result.bookmarks.lines, [2])
    }

    func testPasteFromAnEmptyClipboardIsANoOp() {
        let text = "a\nb"
        let result = BookmarkLineOps.pasteReplacing(text,
                                                    selection: NSRange(location: 0, length: 0),
                                                    bookmarks: state(text, bookmarks: [1]),
                                                    clipboard: "")

        XCTAssertEqual(result.text, text)
        XCTAssertEqual(result.bookmarks.lines, [1])
    }

    func testPasteMapsCaretInsideReplacedContentToTheReplacementStart() {
        let text = "aaa\nbbb\nccc"
        let result = BookmarkLineOps.pasteReplacing(text,
                                                    selection: NSRange(location: 5, length: 0),
                                                    bookmarks: state(text, bookmarks: [2]),
                                                    clipboard: "B")

        XCTAssertEqual(result.text, "aaa\nB\nccc")
        XCTAssertEqual(result.selection, NSRange(location: 4, length: 0))
    }

    // MARK: - Inverse

    func testInverseFlipsEveryLineAndPreservesHalfBookmarkedCount() {
        let text = "a\nb\nc\nd"
        let result = BookmarkLineOps.inverse(text,
                                             selection: NSRange(location: 2, length: 0),
                                             bookmarks: state(text, bookmarks: [2, 4]))

        XCTAssertEqual(result.text, text)
        XCTAssertEqual(result.bookmarks.lines, [1, 3])
        XCTAssertEqual(result.bookmarks.count, 2)
        XCTAssertEqual(result.selection, NSRange(location: 2, length: 0))
    }

    func testInverseOfNoBookmarksBookmarksEveryLine() {
        let result = BookmarkLineOps.inverse("a\nb\nc", selection: NSRange(location: 0, length: 0),
                                             bookmarks: BookmarkState())
        XCTAssertEqual(result.bookmarks.lines, [1, 2, 3])
    }

    func testInverseIncludesTheTrailingEmptyLine() {
        let result = BookmarkLineOps.inverse("a\n", selection: NSRange(location: 0, length: 0),
                                             bookmarks: BookmarkState())
        XCTAssertEqual(result.bookmarks.lines, [1, 2])
    }

    func testInverseOfFullyBookmarkedDocumentClearsBookmarks() {
        let text = "a\nb"
        let result = BookmarkLineOps.inverse(text,
                                             selection: NSRange(location: 0, length: 0),
                                             bookmarks: state(text, bookmarks: [1, 2]))
        XCTAssertEqual(result.bookmarks.count, 0)
    }

    func testInverseOnEmptyDocumentIsANoOp() {
        let result = BookmarkLineOps.inverse("", selection: NSRange(location: 0, length: 0),
                                             bookmarks: BookmarkState())
        XCTAssertEqual(result.text, "")
        XCTAssertTrue(result.bookmarks.isEmpty)
    }

    // MARK: - Command registry

    func testCopyCommandReturnsClipboardPayloadAndLeavesStateAlone() {
        let text = "a\nb\nc"
        let input = DocumentState(text: text,
                                  selection: NSRange(location: 0, length: 0),
                                  bookmarkState: state(text, bookmarks: [1, 3]))

        let output = CommandRegistry.default.execute("bookmark-copy-lines",
                                                     on: input,
                                                     clipboard: nil)

        XCTAssertEqual(output?.clipboard, "a\nc\n")
        XCTAssertEqual(output?.state, input)
    }

    func testPasteCommandUsesTheSuppliedClipboard() {
        let text = "a\nb\nc"
        let input = DocumentState(text: text,
                                  selection: NSRange(location: 0, length: 0),
                                  bookmarkState: state(text, bookmarks: [2]))

        let output = CommandRegistry.default.execute("bookmark-paste-replace-lines",
                                                     on: input,
                                                     clipboard: "B")

        XCTAssertEqual(output?.state.text, "a\nB\nc")
        XCTAssertEqual(output?.state.bookmarkState.lines, [2])
        XCTAssertNil(output?.clipboard)
    }

    func testCutAndRemoveAndInverseRunThroughTheDocumentPath() {
        let text = "a\nb\nc"
        let registry = CommandRegistry.default
        let input = DocumentState(text: text,
                                  selection: NSRange(location: 0, length: 0),
                                  bookmarkState: state(text, bookmarks: [2]))

        XCTAssertEqual(registry.execute("bookmark-cut-lines", on: input)?.text, "a\nc")
        XCTAssertEqual(registry.execute("bookmark-remove-lines", on: input)?.text, "a\nc")
        XCTAssertEqual(registry.execute("bookmark-inverse", on: input)?.bookmarkState.lines, [1, 3])
    }

    func testCutCommandWithoutClipboardStillRemovesLines() {
        // Headless macro replay has no pasteboard; the text transform must
        // still run so the step is not silently dropped.
        let text = "a\nb\nc"
        let input = DocumentState(text: text,
                                  selection: NSRange(location: 0, length: 0),
                                  bookmarkState: state(text, bookmarks: [2]))

        let output = CommandRegistry.default.execute("bookmark-cut-lines",
                                                     on: input,
                                                     clipboard: nil)

        XCTAssertEqual(output?.state.text, "a\nc")
        XCTAssertEqual(output?.clipboard, "b\n")
    }
}
