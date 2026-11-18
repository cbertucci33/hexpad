import XCTest
@testable import HexpadKit

/// P17g-1: Search > Multi-select All/Next variants.
///
/// These tests drive the pure `MultiSelectState` model directly, so caret
/// ordering, overlap collapse, skip exclusion, add-order undo and the no-wrap
/// rule are pinned without an editor window. The option mapping is checked
/// through `SearchEngine` with the exact `SearchOptions` the app pins for each
/// match-mode variant.
final class MultiSelectVariantsTests: XCTestCase {

    /// "foo bar foo baz foo" — three "foo" matches at 0, 8 and 16.
    private let matches = [
        NSRange(location: 0, length: 3),
        NSRange(location: 8, length: 3),
        NSRange(location: 16, length: 3)
    ]

    // MARK: - Select All Occurrences

    func testSelectAllOccurrencesUsesEveryMatchInDocumentOrder() {
        var state = MultiSelectState(carets: MultiCaretState(caretAt: 0))
        state.updateMatches(matches)

        XCTAssertTrue(state.selectAllOccurrences())
        XCTAssertEqual(state.carets.carets, matches)
        XCTAssertEqual(state.addOrder, matches,
                       "add order follows document order, so Undo Latest pops the bottom caret")
        XCTAssertTrue(state.carets.isValid)
        XCTAssertFalse(state.selectAllOccurrences(),
                       "re-selecting the same matches is a no-op")
    }

    func testSelectAllOccurrencesCollapsesOverlappingMatches() {
        var state = MultiSelectState(carets: MultiCaretState(caretAt: 0))
        // Sorted by location these normalize to the single span 0..<8.
        state.updateMatches([
            NSRange(location: 4, length: 4),
            NSRange(location: 0, length: 3),
            NSRange(location: 2, length: 6)
        ])

        XCTAssertTrue(state.selectAllOccurrences())
        XCTAssertEqual(state.carets.carets, [NSRange(location: 0, length: 8)])
        XCTAssertEqual(state.addOrder, [NSRange(location: 0, length: 8)])
    }

    func testSelectAllOccurrencesWithNoMatchesIsANoOp() {
        var state = MultiSelectState(carets: MultiCaretState(caretAt: 5))
        state.updateMatches([])

        XCTAssertFalse(state.selectAllOccurrences())
        XCTAssertEqual(state.carets.carets, [NSRange(location: 5, length: 0)])
        XCTAssertTrue(state.addOrder.isEmpty)
    }

    // MARK: - Multi-select Next (no wrap)

    func testSelectNextAddsFollowingMatchesAndStopsAtDocumentEnd() {
        var state = MultiSelectState(carets: MultiCaretState(caretAt: 0))
        state.updateMatches(matches)

        XCTAssertTrue(state.selectNext())
        XCTAssertEqual(state.carets.carets, [matches[0]])
        XCTAssertTrue(state.selectNext())
        XCTAssertEqual(state.carets.carets, Array(matches.prefix(2)))
        XCTAssertTrue(state.selectNext())
        XCTAssertEqual(state.carets.carets, matches)

        XCTAssertFalse(state.selectNext())
        XCTAssertEqual(state.carets.carets, matches,
                       "N++ stops at the end; it never wraps to the first match")
    }

    func testNextMatchIndexHonoursExcludedMatches() {
        XCTAssertEqual(SearchEngine.nextMatchIndex(from: 0, in: matches, excluding: []), 0)
        XCTAssertEqual(SearchEngine.nextMatchIndex(from: 3, in: matches,
                                                   excluding: [matches[0]]), 1)
        XCTAssertNil(SearchEngine.nextMatchIndex(from: 16, in: matches,
                                                 excluding: [matches[2]]))
        XCTAssertEqual(SearchEngine.nextMatchIndex(from: 0, in: matches,
                                                   excluding: [matches[1]]), 0)
    }

    // MARK: - Skip Current and Go to Next

    func testSkipCurrentExcludesTheSkippedMatchFromLaterSelection() {
        var state = MultiSelectState(carets: MultiCaretState(caret: matches[0]),
                                     addOrder: [matches[0]])
        state.updateMatches(matches)

        XCTAssertTrue(state.skipCurrentAndGoToNext())
        XCTAssertEqual(state.skipped, [matches[0]])
        XCTAssertEqual(state.carets.carets, [matches[1]])
        XCTAssertEqual(state.addOrder, [matches[1]])

        XCTAssertTrue(state.selectNext())
        XCTAssertEqual(state.carets.carets, [matches[1], matches[2]])
        XCTAssertFalse(state.selectNext(),
                       "the skipped occurrence must never be re-added")
    }

    func testSkipCurrentAtDocumentEndStillDropsTheCurrentCaret() {
        var state = MultiSelectState(carets: MultiCaretState(caret: matches[2]),
                                     addOrder: [matches[2]])
        state.updateMatches(matches)

        XCTAssertTrue(state.skipCurrentAndGoToNext())
        XCTAssertTrue(state.carets.isEmpty)
        XCTAssertEqual(state.skipped, [matches[2]])
    }

    // MARK: - Undo Latest

    func testUndoLatestPopsTheMostRecentlyAddedCaret() {
        var state = MultiSelectState(carets: MultiCaretState(caretAt: 0))
        state.updateMatches(matches)
        XCTAssertTrue(state.selectAllOccurrences())

        XCTAssertTrue(state.undoLatest())
        XCTAssertEqual(state.carets.carets, Array(matches.prefix(2)))
        XCTAssertTrue(state.undoLatest())
        XCTAssertEqual(state.carets.carets, [matches[0]])
        XCTAssertTrue(state.undoLatest())
        XCTAssertTrue(state.carets.isEmpty)

        XCTAssertFalse(state.undoLatest(), "nothing left to undo")
    }

    func testUndoLatestAfterMixedNextAndSkip() {
        var state = MultiSelectState(carets: MultiCaretState(caret: matches[0]),
                                     addOrder: [matches[0]])
        state.updateMatches(matches)
        XCTAssertTrue(state.skipCurrentAndGoToNext())   // current -> matches[1]
        XCTAssertTrue(state.selectNext())               // -> matches[2]
        XCTAssertEqual(state.addOrder, [matches[1], matches[2]])

        XCTAssertTrue(state.undoLatest())
        XCTAssertEqual(state.carets.carets, [matches[1]])
        XCTAssertEqual(state.addOrder, [matches[1]])
        XCTAssertTrue(state.undoLatest())
        XCTAssertTrue(state.carets.isEmpty)
    }

    func testUndoLatestWithNoAdditionsIsANoOp() {
        var state = MultiSelectState(carets: MultiCaretState(caretAt: 4))
        state.updateMatches(matches)

        XCTAssertFalse(state.undoLatest())
        XCTAssertEqual(state.carets.carets, [NSRange(location: 4, length: 0)])
    }

    // MARK: - Pinned match-mode options

    func testPinnedModeOptionsProduceTheDocumentedMatchSets() {
        let text = "foo foobar Foo"   // matches at 0, 4 and 11
        let ranges = { (options: SearchOptions) in
            SearchEngine.search(text, pattern: "foo", options: options).map(\.range)
        }

        // Ignore Case: case-insensitive, no whole word.
        XCTAssertEqual(ranges([]), [
            NSRange(location: 0, length: 3),
            NSRange(location: 4, length: 3),
            NSRange(location: 11, length: 3)
        ])
        // Match Case: case-sensitive, no whole word.
        XCTAssertEqual(ranges([.caseSensitive]), [
            NSRange(location: 0, length: 3),
            NSRange(location: 4, length: 3)
        ])
        // Whole Word: case-insensitive + whole word (skips "foobar").
        XCTAssertEqual(ranges([.wholeWord]), [
            NSRange(location: 0, length: 3),
            NSRange(location: 11, length: 3)
        ])
    }

    func testWordTokenDetectionFollowsWholeWordBoundaries() {
        XCTAssertTrue(SearchEngine.isWordToken("foo"))
        XCTAssertTrue(SearchEngine.isWordToken("foo_2"))
        XCTAssertFalse(SearchEngine.isWordToken("a.b"))
        XCTAssertFalse(SearchEngine.isWordToken("foo bar"))
        XCTAssertFalse(SearchEngine.isWordToken(""))
    }

    // MARK: - Registry

    func testRegistryExposesMultiSelectCommandsWithPinnedTitles() {
        let registry = CommandRegistry.default
        let expected: [(String, String)] = [
            ("select-all-occurrences", "Select All Occurrences"),
            ("multi-select-next-ignore-case", "Ignore Case"),
            ("multi-select-next-match-case", "Match Case"),
            ("multi-select-next-whole-word", "Whole Word"),
            ("multi-select-undo-latest", "Undo Latest Multi-select"),
            ("multi-select-skip-current", "Skip Current and Go to Next")
        ]
        XCTAssertEqual(registry.multiSelectCommands.count, expected.count)
        for (identifier, title) in expected {
            XCTAssertEqual(registry.command(for: identifier)?.title, title, identifier)
        }
        for command in registry.multiSelectCommands {
            XCTAssertNotNil(command.viewExecute, command.identifier)
            XCTAssertEqual(registry.command(for: command.identifier)?.title, command.title)
        }
    }
}
