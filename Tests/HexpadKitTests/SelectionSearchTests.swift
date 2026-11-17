import XCTest
@testable import HexpadKit

/// S18c-1: the selection-scoped helpers behind Select and Find Next/Previous
/// and Find (Volatile) Next/Previous. The AppKit layer only resolves the
/// editor's selection, calls these, and applies the resulting range.
final class SelectionSearchTests: XCTestCase {

    // MARK: - Range resolution

    func testSelectionWinsOverWordAtCaret() {
        let text = "alpha beta gamma"
        let range = SearchEngine.selectionSearchRange(
            text: text, selection: NSRange(location: 6, length: 4))
        XCTAssertEqual(range, NSRange(location: 6, length: 4))
    }

    func testEmptySelectionResolvesWordAtCaret() {
        let text = "alpha beta gamma"
        // Caret inside "beta".
        XCTAssertEqual(SearchEngine.selectionSearchRange(
            text: text, selection: NSRange(location: 8, length: 0)),
            NSRange(location: 6, length: 4))
    }

    func testCaretAtWordEdgesBelongsToTheWord() {
        let text = "alpha beta"
        XCTAssertEqual(SearchEngine.selectionSearchRange(
            text: text, selection: NSRange(location: 5, length: 0)),
            NSRange(location: 0, length: 5), "caret just after a word")
        XCTAssertEqual(SearchEngine.selectionSearchRange(
            text: text, selection: NSRange(location: 6, length: 0)),
            NSRange(location: 6, length: 4), "caret at the word's first character")
        XCTAssertEqual(SearchEngine.selectionSearchRange(
            text: text, selection: NSRange(location: 10, length: 0)),
            NSRange(location: 6, length: 4), "caret at the end of the buffer")
    }

    func testCaretOffAWordHasNoRange() {
        XCTAssertNil(SearchEngine.selectionSearchRange(
            text: "alpha beta ", selection: NSRange(location: 11, length: 0)),
            "a caret on a trailing space is off any word")
        XCTAssertNil(SearchEngine.selectionSearchRange(
            text: "  ", selection: NSRange(location: 1, length: 0)))
        XCTAssertNil(SearchEngine.selectionSearchRange(
            text: "", selection: NSRange(location: 0, length: 0)))
    }

    func testWordRangeUsesUTF16Offsets() {
        let text = "a😀bcd"
        // "bcd" starts after a (1) + emoji (2 UTF-16 units).
        XCTAssertEqual(SearchEngine.wordRange(at: 3, in: text),
                       NSRange(location: 3, length: 3))
        XCTAssertNil(SearchEngine.wordRange(at: 2, in: text),
                     "a surrogate half is not a word character")
    }

    func testUnderscoreCountsAsWordCharacter() {
        XCTAssertEqual(SearchEngine.wordRange(at: 2, in: "foo_bar baz"),
                       NSRange(location: 0, length: 7))
    }

    func testOutOfBoundsSelectionIsClamped() {
        let text = "abc"
        XCTAssertEqual(SearchEngine.selectionSearchRange(
            text: text, selection: NSRange(location: 1, length: 100)),
            NSRange(location: 1, length: 2))
        XCTAssertEqual(SearchEngine.selectionSearchRange(
            text: text, selection: NSRange(location: 99, length: 5)),
            NSRange(location: 0, length: 3), "clamped to the end, then word-tested")
    }

    // MARK: - Target index

    private func matches(_ text: String, _ pattern: String) -> [SearchMatch] {
        SearchEngine.search(text, pattern: pattern, options: [])
    }

    func testNextSkipsTheAnchorOccurrence() {
        let found = matches("foo bar foo baz foo", "foo")
        let anchor = NSRange(location: 0, length: 3)
        XCTAssertEqual(SearchEngine.targetMatchIndex(in: found, from: anchor,
                                                     direction: .next, wrap: false), 1)
    }

    func testNextWrapsToFirstMatchWhenEnabled() {
        let found = matches("foo bar foo", "foo")
        let anchor = NSRange(location: 8, length: 3)
        XCTAssertEqual(SearchEngine.targetMatchIndex(in: found, from: anchor,
                                                     direction: .next, wrap: true), 0)
    }

    func testNextWithoutWrapAtTheLastMatchHasNoTarget() {
        let found = matches("foo bar foo", "foo")
        let anchor = NSRange(location: 8, length: 3)
        XCTAssertNil(SearchEngine.targetMatchIndex(in: found, from: anchor,
                                                   direction: .next, wrap: false))
    }

    func testPreviousSkipsTheAnchorOccurrence() {
        let found = matches("foo bar foo baz foo", "foo")
        let anchor = NSRange(location: 8, length: 3)
        XCTAssertEqual(SearchEngine.targetMatchIndex(in: found, from: anchor,
                                                     direction: .previous, wrap: false), 0)
    }

    func testPreviousWrapsToLastMatchWhenEnabled() {
        let found = matches("foo bar foo", "foo")
        let anchor = NSRange(location: 0, length: 3)
        XCTAssertEqual(SearchEngine.targetMatchIndex(in: found, from: anchor,
                                                     direction: .previous, wrap: true), 1)
    }

    func testPreviousWithoutWrapAtTheFirstMatchHasNoTarget() {
        let found = matches("foo bar foo", "foo")
        let anchor = NSRange(location: 0, length: 3)
        XCTAssertNil(SearchEngine.targetMatchIndex(in: found, from: anchor,
                                                   direction: .previous, wrap: false))
    }

    func testZeroLengthAnchorCanSelectAMatchStartingThere() {
        let found = matches("foo bar foo", "foo")
        let caret = NSRange(location: 8, length: 0)
        XCTAssertEqual(SearchEngine.targetMatchIndex(in: found, from: caret,
                                                     direction: .next, wrap: false), 1)
        XCTAssertEqual(SearchEngine.targetMatchIndex(in: found, from: caret,
                                                     direction: .previous, wrap: false), 0)
    }

    func testNoMatchesHasNoTarget() {
        XCTAssertNil(SearchEngine.targetMatchIndex(in: [], from: NSRange(location: 0, length: 3),
                                                   direction: .next, wrap: true))
    }

    /// The index helper and range resolution compose the way the actions use
    /// them: select the second word, jump to the third one.
    func testSelectionRangeAndTargetCompose() {
        let text = "alpha beta alpha beta alpha"
        let selection = NSRange(location: 11, length: 5)
        let anchor = try? XCTUnwrap(SearchEngine.selectionSearchRange(text: text,
                                                                      selection: selection))
        let found = matches(text, "alpha")
        XCTAssertEqual(SearchEngine.targetMatchIndex(in: found, from: anchor!,
                                                     direction: .next, wrap: true), 2)
    }
}
