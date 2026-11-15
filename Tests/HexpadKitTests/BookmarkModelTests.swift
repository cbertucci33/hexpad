import XCTest
@testable import HexpadKit

final class BookmarkModelTests: XCTestCase {

    // MARK: - Fixtures

    /// Five logical lines, all non-empty, so every line has a distinct start.
    private let fixture = "one\ntwo\nthree\nfour\nfive"

    /// Nine logical lines, for navigation tests that need bookmarks past the
    /// five-line fixture.
    private let longFixture = (1...9).map { "line\($0)" }.joined(separator: "\n")

    private func makeModel(_ text: String? = nil, bookmarked lines: [Int] = []) -> BookmarkModel {
        var state = BookmarkState()
        for line in lines {
            state.add(line: line)
        }
        return BookmarkModel(text: text ?? fixture, bookmarkState: state)
    }

    /// UTF-16 span of `line`, including its terminator.
    private func lineSpan(_ line: Int, in text: String) -> NSRange {
        let start = GutterGeometry.firstCharIndex(of: line, in: text)
        let end = line < GutterGeometry.lineCount(in: text)
            ? GutterGeometry.firstCharIndex(of: line + 1, in: text)
            : text.utf16.count
        return NSRange(location: start, length: end - start)
    }

    // MARK: - Add / remove / toggle / clear

    func testAddBookmarksLineAndRejectsDuplicates() {
        var model = makeModel()

        XCTAssertTrue(model.add(line: 3))
        XCTAssertTrue(model.isBookmarked(line: 3))
        XCTAssertEqual(model.bookmarks, [Bookmark(line: 3)])
        XCTAssertFalse(model.add(line: 3), "line is already bookmarked")
        XCTAssertEqual(model.count, 1)
    }

    func testAddRejectsLinesOutsideTheDocument() {
        var model = makeModel()

        XCTAssertFalse(model.add(line: 0))
        XCTAssertFalse(model.add(line: -4))
        XCTAssertFalse(model.add(line: 6))
        XCTAssertFalse(model.add(line: 99))
        XCTAssertTrue(model.isEmpty)
    }

    func testRemoveReportsWhetherLineWasBookmarked() {
        var model = makeModel(bookmarked: [2, 4])

        XCTAssertTrue(model.remove(line: 2))
        XCTAssertFalse(model.remove(line: 2), "already removed")
        XCTAssertEqual(model.bookmarks.map(\.line), [4])
    }

    func testToggleAddsThenRemoves() {
        var model = makeModel()

        XCTAssertTrue(model.toggle(line: 2))
        XCTAssertTrue(model.isBookmarked(line: 2))
        XCTAssertFalse(model.toggle(line: 2))
        XCTAssertFalse(model.isBookmarked(line: 2))
        XCTAssertTrue(model.isEmpty)
    }

    func testToggleRejectsLinesOutsideTheDocument() {
        var model = makeModel()

        XCTAssertFalse(model.toggle(line: 0))
        XCTAssertFalse(model.toggle(line: 6))
        XCTAssertTrue(model.isEmpty)
    }

    func testClearRemovesEveryBookmark() {
        var model = makeModel(bookmarked: [1, 3, 5])

        model.clear()

        XCTAssertTrue(model.isEmpty)
        XCTAssertEqual(model.count, 0)
        XCTAssertEqual(model.bookmarks, [])
    }

    func testNotesMoveWithTheirBookmark() {
        var model = makeModel()
        XCTAssertTrue(model.add(line: 3, note: "review this"))
        XCTAssertEqual(model.note(forLine: 3), "review this")

        XCTAssertTrue(model.setNote("done", forLine: 3))
        XCTAssertEqual(model.note(forLine: 3), "done")

        XCTAssertFalse(model.setNote("missing", forLine: 4))
        XCTAssertEqual(model.bookmarks, [Bookmark(line: 3, note: "done")])
    }

    // MARK: - Ordering

    func testBookmarksAreAlwaysSortedByLine() {
        var model = makeModel()

        model.add(line: 5)
        model.add(line: 1)
        model.add(line: 3)
        model.add(line: 2)

        XCTAssertEqual(model.bookmarks.map(\.line), [1, 2, 3, 5])
        XCTAssertEqual(model.bookmarkState.lines, [1, 2, 3, 5])
    }

    // MARK: - Next / previous navigation

    func testNextWrapsFromMiddleAndEnd() {
        let model = makeModel(longFixture, bookmarked: [2, 5, 9])

        XCTAssertEqual(model.next(afterLine: 1)?.line, 2)
        XCTAssertEqual(model.next(afterLine: 2)?.line, 5, "strictly after the caret line")
        XCTAssertEqual(model.next(afterLine: 6)?.line, 9)
        XCTAssertEqual(model.next(afterLine: 9)?.line, 2, "wraps to the first bookmark")
        XCTAssertEqual(model.next(afterLine: 100)?.line, 2, "past the end wraps")
    }

    func testPreviousWrapsFromMiddleAndStart() {
        let model = makeModel(longFixture, bookmarked: [2, 5, 9])

        XCTAssertEqual(model.previous(beforeLine: 10)?.line, 9)
        XCTAssertEqual(model.previous(beforeLine: 5)?.line, 2, "strictly before the caret line")
        XCTAssertEqual(model.previous(beforeLine: 3)?.line, 2)
        XCTAssertEqual(model.previous(beforeLine: 2)?.line, 9, "wraps to the last bookmark")
        XCTAssertEqual(model.previous(beforeLine: 0)?.line, 9, "before the start wraps")
    }

    func testNavigationWithNoBookmarksReturnsNil() {
        let model = makeModel()

        XCTAssertNil(model.next(afterLine: 1))
        XCTAssertNil(model.previous(beforeLine: 1))
    }

    func testNavigationWithOneBookmarkReturnsIt() {
        let model = makeModel(bookmarked: [4])

        XCTAssertEqual(model.next(afterLine: 4)?.line, 4)
        XCTAssertEqual(model.next(afterLine: 1)?.line, 4)
        XCTAssertEqual(model.previous(beforeLine: 4)?.line, 4)
        XCTAssertEqual(model.previous(beforeLine: 9)?.line, 4)
    }

    // MARK: - Remapping: insertions

    func testRemapInsertionBeforeBookmarkShiftsLineDown() {
        var model = makeModel(bookmarked: [3])
        let edit = FoldTextEdit.insertion(at: 0, length: ("zero\n" as NSString).length)
        let newText = "zero\n" + fixture

        model.remap(for: edit, in: newText)

        XCTAssertEqual(model.text, newText)
        XCTAssertEqual(model.bookmarks.map(\.line), [4])
    }

    func testRemapInsertionAtLineStartShiftsLineDown() {
        var model = makeModel(bookmarked: [3])
        let start = GutterGeometry.firstCharIndex(of: 3, in: fixture)
        let edit = FoldTextEdit.insertion(at: start, length: 1)
        let newText = (fixture as NSString).replacingCharacters(
            in: NSRange(location: start, length: 0),
            with: "\n"
        )

        model.remap(for: edit, in: newText)

        XCTAssertEqual(model.bookmarks.map(\.line), [4])
    }

    func testRemapInsertionAtLineStartWithoutNewlineKeepsLine() {
        var model = makeModel(bookmarked: [2])
        let start = GutterGeometry.firstCharIndex(of: 2, in: fixture)
        let edit = FoldTextEdit.insertion(at: start, length: 2)
        let newText = (fixture as NSString).replacingCharacters(
            in: NSRange(location: start, length: 0),
            with: "XY"
        )

        model.remap(for: edit, in: newText)

        XCTAssertEqual(model.bookmarks.map(\.line), [2])
    }

    func testRemapInsertionInsideBookmarkedLineKeepsLine() {
        var model = makeModel(bookmarked: [3])
        let inside = GutterGeometry.firstCharIndex(of: 3, in: fixture) + 2
        let edit = FoldTextEdit.insertion(at: inside, length: 3)
        let newText = (fixture as NSString).replacingCharacters(
            in: NSRange(location: inside, length: 0),
            with: "abc"
        )

        model.remap(for: edit, in: newText)

        XCTAssertEqual(model.bookmarks.map(\.line), [3])
    }

    func testRemapInsertionAfterBookmarkKeepsLine() {
        var model = makeModel(bookmarked: [2])
        let afterLine = GutterGeometry.firstCharIndex(of: 4, in: fixture)
        let edit = FoldTextEdit.insertion(at: afterLine, length: 5)
        let newText = (fixture as NSString).replacingCharacters(
            in: NSRange(location: afterLine, length: 0),
            with: "added"
        )

        model.remap(for: edit, in: newText)

        XCTAssertEqual(model.bookmarks.map(\.line), [2])
    }

    // MARK: - Remapping: deletions

    func testRemapDeletionOfNonBookmarkedLineAboveShiftsLineUp() {
        var model = makeModel(bookmarked: [3])
        let span = lineSpan(1, in: fixture)
        let edit = FoldTextEdit.deletion(span)
        let newText = (fixture as NSString).replacingCharacters(in: span, with: "")

        model.remap(for: edit, in: newText)

        XCTAssertEqual(model.bookmarks.map(\.line), [2])
    }

    func testRemapDeletionOfNonBookmarkedLineBelowKeepsLine() {
        var model = makeModel(bookmarked: [2])
        let span = lineSpan(4, in: fixture)
        let edit = FoldTextEdit.deletion(span)
        let newText = (fixture as NSString).replacingCharacters(in: span, with: "")

        model.remap(for: edit, in: newText)

        XCTAssertEqual(model.bookmarks.map(\.line), [2])
    }

    func testRemapDeletionOfBookmarkedLineRemovesBookmark() {
        var model = makeModel(bookmarked: [3])
        let span = lineSpan(3, in: fixture)
        let edit = FoldTextEdit.deletion(span)
        let newText = (fixture as NSString).replacingCharacters(in: span, with: "")

        model.remap(for: edit, in: newText)

        XCTAssertTrue(model.isEmpty)
        XCTAssertEqual(model.lineCount, 4)
    }

    func testRemapDeletionOfSeveralLinesDropsBookmarksAndShiftsSurvivors() {
        var model = makeModel(bookmarked: [2, 3, 4, 5])
        let span = NSRange(
            location: GutterGeometry.firstCharIndex(of: 2, in: fixture),
            length: GutterGeometry.firstCharIndex(of: 5, in: fixture)
                - GutterGeometry.firstCharIndex(of: 2, in: fixture)
        )
        let edit = FoldTextEdit.deletion(span)
        let newText = (fixture as NSString).replacingCharacters(in: span, with: "")

        model.remap(for: edit, in: newText)

        XCTAssertEqual(newText, "one\nfive")
        XCTAssertEqual(model.bookmarks.map(\.line), [2], "only the former line 5 survives, now line 2")
    }

    func testRemapDeletionOfWholeDocumentClearsBookmarks() {
        var model = makeModel(bookmarked: [1, 3, 5])
        let span = NSRange(location: 0, length: (fixture as NSString).length)
        let edit = FoldTextEdit.deletion(span)

        model.remap(for: edit, in: "")

        XCTAssertTrue(model.isEmpty)
    }

    // MARK: - Remapping: replacements and purity

    func testRemapReplacementInsideLineKeepsLine() {
        var model = makeModel(bookmarked: [3, 4])
        let edit = FoldTextEdit(location: 9, replacedLength: 2, insertedLength: 5)
        let newText = (fixture as NSString).replacingCharacters(
            in: NSRange(location: 9, length: 2),
            with: "ABCDE"
        )

        model.remap(for: edit, in: newText)

        XCTAssertEqual(model.bookmarks.map(\.line), [3, 4])
    }

    func testRemapPreservesNotes() {
        var model = makeModel()
        model.add(line: 3, note: "keep me")
        let edit = FoldTextEdit.insertion(at: 0, length: 5)
        let newText = "zero\n" + fixture

        model.remap(for: edit, in: newText)

        XCTAssertEqual(model.bookmarks, [Bookmark(line: 4, note: "keep me")])
        XCTAssertEqual(model.note(forLine: 4), "keep me")
    }

    func testRemapIsPureUntilApplied() {
        let model = makeModel(bookmarked: [3])
        let newText = "zero\n" + fixture
        let edit = FoldTextEdit.insertion(at: 0, length: 5)

        let remapped = model.remapped(for: edit, in: newText)
        XCTAssertEqual(remapped.bookmarks.map(\.line), [4])
        XCTAssertEqual(remapped.text, newText)

        XCTAssertEqual(model.bookmarks.map(\.line), [3], "remapping must not mutate the receiver")
        XCTAssertEqual(model.text, fixture)
        XCTAssertEqual(model.remappedState(for: edit, in: newText).lines, [4])
    }

    // MARK: - Validity against the current text

    func testInitDropsBookmarksOnLinesTheTextDoesNotHave() {
        var state = BookmarkState()
        state.add(line: 1)
        state.add(line: 3)
        state.add(line: 9)

        let model = BookmarkModel(text: fixture, bookmarkState: state)

        XCTAssertEqual(model.bookmarks.map(\.line), [1, 3])
        XCTAssertEqual(model.lineCount, 5)
    }

    func testUpdateTextDropsBookmarksOnRemovedLines() {
        var model = makeModel(bookmarked: [1, 3, 5])

        model.updateText("alpha\nbeta")

        XCTAssertEqual(model.text, "alpha\nbeta")
        XCTAssertEqual(model.bookmarks.map(\.line), [1])
        XCTAssertEqual(model.revalidatedState(in: "x\ny\nz").lines, [1])
    }

    func testNewEmptyDocumentHasOneLine() {
        var model = makeModel("", bookmarked: [])

        XCTAssertEqual(model.lineCount, 1)
        XCTAssertTrue(model.add(line: 1))
        XCTAssertEqual(model.bookmarks.map(\.line), [1])
        XCTAssertFalse(model.add(line: 2))
    }

    // MARK: - Codable

    func testCodableRoundTrip() throws {
        let state = BookmarkState(bookmarks: [
            Bookmark(line: 2, note: "first"),
            Bookmark(line: 7),
            Bookmark(line: 5, note: "")
        ])

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(BookmarkState.self, from: data)

        XCTAssertEqual(decoded, state)
        XCTAssertEqual(decoded.bookmarks.map(\.line), [2, 5, 7])
        XCTAssertEqual(decoded.note(forLine: 2), "first")
        XCTAssertNil(decoded.note(forLine: 7))
        XCTAssertEqual(decoded.note(forLine: 5), "")
    }

    func testDecodingIgnoresOrderAndDuplicateLines() throws {
        let json = """
        {"bookmarks":[{"line":5},{"line":2,"note":"kept"},{"line":2,"note":"dropped"}]}
        """
        let decoded = try JSONDecoder().decode(BookmarkState.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.bookmarks.map(\.line), [2, 5])
        XCTAssertEqual(decoded.note(forLine: 2), "kept", "first bookmark for a line wins")
    }

    func testDecodingMissingBookmarksIsEmpty() throws {
        let decoded = try JSONDecoder().decode(BookmarkState.self, from: Data("{}".utf8))
        XCTAssertTrue(decoded.isEmpty)
    }

    // MARK: - Session projection

    func testSessionProjectionIsSortedAndOmitsMissingNotes() {
        let state = BookmarkState(bookmarks: [
            Bookmark(line: 7),
            Bookmark(line: 2, note: "first"),
            Bookmark(line: 5, note: "")
        ])

        let data = state.toSessionData()
        let entries = data["bookmarks"] as? [[String: Any]] ?? []

        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries.compactMap { $0["line"] as? Int }, [2, 5, 7])
        XCTAssertEqual(entries[0]["note"] as? String, "first")
        XCTAssertEqual(entries[1]["note"] as? String, "", "an empty note is still a note")
        XCTAssertNil(entries[2]["note"], "a bookmark without a note omits the key")
    }

    func testSessionProjectionRoundTripsThroughJSONSerialization() throws {
        let state = BookmarkState(bookmarks: [
            Bookmark(line: 1, note: "with note"),
            Bookmark(line: 3)
        ])
        let data = state.toSessionData()

        // JSONSerialization turns Ints into NSNumbers; restoring must accept
        // both, exactly like the live session file does.
        let encoded = try JSONSerialization.data(withJSONObject: data)
        let decodedObject = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        let restored = BookmarkState.fromSessionData(decodedObject)

        XCTAssertEqual(restored, state)
        XCTAssertEqual(restored.note(forLine: 1), "with note")
        XCTAssertNil(restored.note(forLine: 3))
    }

    func testSessionProjectionWithoutBookmarksIsEmpty() {
        let data = BookmarkState().toSessionData()

        XCTAssertEqual((data["bookmarks"] as? [[String: Any]])?.count, 0)
        XCTAssertTrue(BookmarkState.fromSessionData(data).isEmpty)
    }

    func testSessionProjectionSkipsMalformedEntriesIndividually() {
        let data: [String: Any] = [
            "bookmarks": [
                ["line": 2, "note": "kept"],
                ["note": "missing line"],
                ["line": 0],
                ["line": -3],
                ["line": "4"],
                ["line": 5, "note": 42],
                ["line": 6, "note": "also kept"]
            ]
        ]

        let restored = BookmarkState.fromSessionData(data)

        XCTAssertEqual(restored.bookmarks.map(\.line), [2, 6])
        XCTAssertEqual(restored.note(forLine: 2), "kept")
        XCTAssertEqual(restored.note(forLine: 6), "also kept")
    }

    func testSessionProjectionWithoutKeyIsEmpty() {
        XCTAssertTrue(BookmarkState.fromSessionData(nil).isEmpty)
        XCTAssertTrue(BookmarkState.fromSessionData([:]).isEmpty)
        XCTAssertTrue(BookmarkState.fromSessionData(["bookmarks": "not an array"]).isEmpty)
    }
}
