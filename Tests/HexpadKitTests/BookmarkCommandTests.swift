import XCTest
@testable import HexpadKit

/// Bookmark navigation through the command registry.
///
/// The bookmark commands are the first state-aware commands: they need the
/// document's ``BookmarkState``, so they run through `execute(_:on:)`. The
/// text-only `execute(_:text:selection:)` path must keep working unchanged.
final class BookmarkCommandTests: XCTestCase {

    // MARK: - Helpers

    private let registry = CommandRegistry.default

    /// `text` is "a\nb\nc\nd\ne" in the navigation tests, so line starts are
    /// 0, 2, 4, 6, 8.
    private func makeState(_ text: String,
                           caret: Int,
                           bookmarks: [Int] = []) -> DocumentState {
        DocumentState(
            text: text,
            selection: NSRange(location: caret, length: 0),
            bookmarkState: BookmarkState(bookmarks: bookmarks.map { Bookmark(line: $0) })
        )
    }

    // MARK: - Registration

    func testBookmarkCommandsAreRegisteredInMenuOrder() {
        XCTAssertEqual(registry.bookmarkCommands.map(\.identifier), [
            "bookmark-toggle",
            "bookmark-next",
            "bookmark-prev",
            "bookmark-clear-all",
            "bookmark-cut-lines",
            "bookmark-copy-lines",
            "bookmark-paste-replace-lines",
            "bookmark-remove-lines",
            "bookmark-inverse"
        ])
        XCTAssertEqual(registry.bookmarkCommands.map(\.title), [
            "Toggle Bookmark",
            "Next Bookmark",
            "Previous Bookmark",
            "Clear All Bookmarks",
            "Cut Bookmarked Lines",
            "Copy Bookmarked Lines",
            "Paste to (Replace) Bookmarked Lines",
            "Remove Bookmarked Lines",
            "Inverse Bookmarks"
        ])
        XCTAssertNotNil(registry.command(for: "bookmark-toggle"))
        XCTAssertNotNil(registry.command(for: "bookmark-next"))
        XCTAssertNotNil(registry.command(for: "bookmark-prev"))
        XCTAssertNotNil(registry.command(for: "bookmark-clear-all"))
        XCTAssertNotNil(registry.command(for: "bookmark-cut-lines"))
        XCTAssertNotNil(registry.command(for: "bookmark-copy-lines"))
        XCTAssertNotNil(registry.command(for: "bookmark-paste-replace-lines"))
        XCTAssertNotNil(registry.command(for: "bookmark-remove-lines"))
        XCTAssertNotNil(registry.command(for: "bookmark-inverse"))
    }

    func testAllCommandsKeepsLineCommandsFirst() {
        XCTAssertEqual(registry.allCommands.map(\.identifier),
                       registry.commands.map(\.identifier)
                       + registry.bookmarkCommands.map(\.identifier)
                       + registry.toolCommands.map(\.identifier)
                       + registry.dateCommands.map(\.identifier)
                       + registry.lineOpCommands.map(\.identifier)
                       + registry.caseCommands.map(\.identifier)
                       + registry.indentCommands.map(\.identifier)
                       + registry.viewCommands.map(\.identifier)
                       + registry.tokenStyleCommands.map(\.identifier))
        // Contract: the line-editing group stays first and unchanged, then
        // bookmarks, then Tools, Line Ops, case and view commands in registry
        // order.
        XCTAssertEqual(registry.allCommands.map(\.identifier), [
            "duplicate-line",
            "delete-line",
            "move-line-up",
            "move-line-down",
            "toggle-line-comment",
            "uppercase",
            "lowercase",
            "bookmark-toggle",
            "bookmark-next",
            "bookmark-prev",
            "bookmark-clear-all",
            "bookmark-cut-lines",
            "bookmark-copy-lines",
            "bookmark-paste-replace-lines",
            "bookmark-remove-lines",
            "bookmark-inverse",
            "hash-md5",
            "hash-sha1",
            "hash-sha256",
            "insert-date",
            "insert-time",
            "insert-datetime",
            "insert-datetime-short",
            "insert-datetime-long",
            "insert-datetime-custom",
            "sort-lines-ascending",
            "sort-lines-descending",
            "remove-duplicate-lines",
            "remove-blank-lines",
            "case-uppercase",
            "case-lowercase",
            "case-proper",
            "case-proper-blend",
            "case-sentence",
            "case-sentence-blend",
            "case-invert",
            "case-random",
            "indent-increase",
            "indent-decrease",
            "fold-all",
            "unfold-all",
            "fold-current-level",
            "unfold-current-level",
            "fold-level-1",
            "fold-level-2",
            "fold-level-3",
            "fold-level-4",
            "fold-level-5",
            "fold-level-6",
            "fold-level-7",
            "fold-level-8",
            "unfold-level-1",
            "unfold-level-2",
            "unfold-level-3",
            "unfold-level-4",
            "unfold-level-5",
            "unfold-level-6",
            "unfold-level-7",
            "unfold-level-8",
            "toggle-word-wrap",
            "style-all-occurrences-1",
            "style-all-occurrences-2",
            "style-all-occurrences-3",
            "style-all-occurrences-4",
            "style-all-occurrences-5",
            "style-one-token-1",
            "style-one-token-2",
            "style-one-token-3",
            "style-one-token-4",
            "style-one-token-5",
            "clear-style-1",
            "clear-style-2",
            "clear-style-3",
            "clear-style-4",
            "clear-style-5",
            "clear-style-all",
            "jump-up-1",
            "jump-up-2",
            "jump-up-3",
            "jump-up-4",
            "jump-up-5",
            "jump-down-1",
            "jump-down-2",
            "jump-down-3",
            "jump-down-4",
            "jump-down-5",
            "copy-styled-text-1",
            "copy-styled-text-2",
            "copy-styled-text-3",
            "copy-styled-text-4",
            "copy-styled-text-5",
            "copy-styled-text-all"
        ])
    }

    // MARK: - Toggle

    func testToggleCreatesBookmarkOnCurrentLine() {
        let input = makeState("a\nb\nc", caret: 2)
        let result = registry.execute("bookmark-toggle", on: input)

        XCTAssertEqual(result?.bookmarkState.lines, [2])
        XCTAssertEqual(result?.text, input.text)
        XCTAssertEqual(result?.selection, input.selection)
    }

    func testToggleRemovesBookmarkOnCurrentLine() {
        let input = makeState("a\nb\nc", caret: 2, bookmarks: [1, 2, 3])
        let result = registry.execute("bookmark-toggle", on: input)

        XCTAssertEqual(result?.bookmarkState.lines, [1, 3])
    }

    func testToggleUsesTheLineWhereTheSelectionStarts() {
        var input = makeState("a\nb\nc\nd", caret: 2, bookmarks: [])
        input.selection = NSRange(location: 2, length: 4) // lines 2 through 3

        let result = registry.execute("bookmark-toggle", on: input)

        XCTAssertEqual(result?.bookmarkState.lines, [2])
        XCTAssertEqual(result?.selection, NSRange(location: 2, length: 4))
    }

    func testToggleBookmarksTheTrailingEmptyLine() {
        // "a\nb\n" has three logical lines; the final line is empty.
        let input = makeState("a\nb\n", caret: 4)
        let result = registry.execute("bookmark-toggle", on: input)

        XCTAssertEqual(result?.bookmarkState.lines, [3])
    }

    // MARK: - Next

    func testNextMovesToTheNextBookmarkedLineStart() {
        let input = makeState("a\nb\nc\nd\ne", caret: 0, bookmarks: [2, 4])
        let result = registry.execute("bookmark-next", on: input)

        XCTAssertEqual(result?.selection, NSRange(location: 2, length: 0))
        XCTAssertEqual(result?.text, input.text)
        XCTAssertEqual(result?.bookmarkState, input.bookmarkState)
    }

    func testNextFromABookmarkedLineAdvancesPastIt() {
        let input = makeState("a\nb\nc\nd\ne", caret: 2, bookmarks: [2, 4])
        let result = registry.execute("bookmark-next", on: input)

        XCTAssertEqual(result?.selection, NSRange(location: 6, length: 0))
    }

    func testNextWrapsFromTheLastLineToTheFirstBookmark() {
        let input = makeState("a\nb\nc\nd\ne", caret: 8, bookmarks: [2, 4])
        let result = registry.execute("bookmark-next", on: input)

        XCTAssertEqual(result?.selection, NSRange(location: 2, length: 0))
    }

    func testNextWrapsWhenCaretIsBelowTheLastBookmark() {
        let input = makeState("a\nb\nc\nd\ne", caret: 6, bookmarks: [2])
        let result = registry.execute("bookmark-next", on: input)

        XCTAssertEqual(result?.selection, NSRange(location: 2, length: 0))
    }

    func testNextWithASingleBookmarkWrapsOntoItself() {
        let input = makeState("a\nb\nc", caret: 2, bookmarks: [2])
        let result = registry.execute("bookmark-next", on: input)

        XCTAssertEqual(result?.selection, NSRange(location: 2, length: 0))
    }

    func testNextWithoutBookmarksIsANoOp() {
        let input = makeState("a\nb\nc", caret: 4, bookmarks: [])
        let result = registry.execute("bookmark-next", on: input)

        XCTAssertEqual(result, input)
    }

    // MARK: - Previous

    func testPreviousMovesToThePreviousBookmarkedLineStart() {
        let input = makeState("a\nb\nc\nd\ne", caret: 6, bookmarks: [2, 4])
        let result = registry.execute("bookmark-prev", on: input)

        XCTAssertEqual(result?.selection, NSRange(location: 2, length: 0))
        XCTAssertEqual(result?.text, input.text)
        XCTAssertEqual(result?.bookmarkState, input.bookmarkState)
    }

    func testPreviousFromABookmarkedLineMovesBeforeIt() {
        let input = makeState("a\nb\nc\nd\ne", caret: 6, bookmarks: [2, 4])
        let result = registry.execute("bookmark-prev", on: input)

        XCTAssertEqual(result?.selection, NSRange(location: 2, length: 0))
    }

    func testPreviousWrapsFromTheFirstLineToTheLastBookmark() {
        let input = makeState("a\nb\nc\nd\ne", caret: 0, bookmarks: [2, 4])
        let result = registry.execute("bookmark-prev", on: input)

        XCTAssertEqual(result?.selection, NSRange(location: 6, length: 0))
    }

    func testPreviousWithASingleBookmarkWrapsOntoItself() {
        let input = makeState("a\nb\nc", caret: 0, bookmarks: [2])
        let result = registry.execute("bookmark-prev", on: input)

        XCTAssertEqual(result?.selection, NSRange(location: 2, length: 0))
    }

    func testPreviousWithoutBookmarksIsANoOp() {
        let input = makeState("a\nb\nc", caret: 4, bookmarks: [])
        let result = registry.execute("bookmark-prev", on: input)

        XCTAssertEqual(result, input)
    }

    // MARK: - Clear all

    func testClearAllEmptiesBookmarkStateAndLeavesTextAlone() {
        let input = makeState("a\nb\nc", caret: 2, bookmarks: [1, 3])
        let result = registry.execute("bookmark-clear-all", on: input)

        XCTAssertEqual(result?.bookmarkState.count, 0)
        XCTAssertEqual(result?.text, input.text)
        XCTAssertEqual(result?.selection, input.selection)
    }

    func testClearAllOnAnEmptyStateIsANoOp() {
        let input = makeState("a\nb", caret: 0, bookmarks: [])
        XCTAssertEqual(registry.execute("bookmark-clear-all", on: input), input)
    }

    // MARK: - Backward compatibility

    func testLegacyTextSelectionPathStillRunsLineCommands() {
        // The original entry point must be untouched: no DocumentState, no
        // bookmarks, same LineOps result as before.
        let result = registry.execute("duplicate-line",
                                      text: "a\nb",
                                      selection: NSRange(location: 0, length: 0))
        XCTAssertEqual(result?.text, "a\na\nb")
        XCTAssertEqual(result?.selection, NSRange(location: 2, length: 0))
    }

    func testLegacyPathBookmarkCommandsAreIdentityNoOps() {
        // Bookmarks cannot be inspected or changed without a bookmark state,
        // so the old path returns its input untouched.
        for identifier in registry.bookmarkCommands.map(\.identifier) {
            let result = registry.execute(identifier,
                                          text: "a\nb",
                                          selection: NSRange(location: 2, length: 0))
            XCTAssertEqual(result?.text, "a\nb", identifier)
            XCTAssertEqual(result?.selection, NSRange(location: 2, length: 0), identifier)
        }
    }

    func testDocumentPathRunsTextOnlyCommandsAndPreservesBookmarks() {
        let bookmarks = BookmarkState(bookmarks: [Bookmark(line: 2)])
        let input = DocumentState(text: "abc",
                                  selection: NSRange(location: 0, length: 3),
                                  bookmarkState: bookmarks)

        let result = registry.execute("uppercase", on: input)

        XCTAssertEqual(result?.text, "ABC")
        XCTAssertEqual(result?.selection, NSRange(location: 0, length: 3))
        XCTAssertEqual(result?.bookmarkState, bookmarks)
    }

    func testDocumentPathUnknownIdentifierReturnsNil() {
        let input = makeState("abc", caret: 0)
        XCTAssertNil(registry.execute("not-a-command", on: input))
    }

    func testCustomRegistryWithoutBookmarkCommandsStaysBookmarkFree() {
        let registry = CommandRegistry(commands: [
            EditorCommand(identifier: "noop", title: "No-op") { text, selection in
                (text, selection)
            }
        ])

        XCTAssertTrue(registry.bookmarkCommands.isEmpty)
        XCTAssertNil(registry.command(for: "bookmark-toggle"))
        let input = makeState("abc", caret: 0)
        XCTAssertEqual(registry.execute("noop", on: input), input)
    }
}
