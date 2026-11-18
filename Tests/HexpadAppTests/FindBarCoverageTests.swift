import XCTest
import AppKit
import HexpadKit
@testable import Hexpad

/// U2: AppKit-level coverage for the main FindBar (not IncrementalSearchBar).
///
/// Existing suites pin layout, match-case/extended mode, Find All, Select and
/// Find and the volatile search commands. This file fills the gaps in the
/// bar's own state machine: visibility, query history, option flags, replace
/// paths, match navigation, the search-field delegate and the document-change
/// observer. Every assertion reads observable state (flags, labels, the
/// editor's selection, temporary attributes or posted notifications) rather
/// than reaching into the bar's private storage.
final class FindBarCoverageTests: XCTestCase {

    private let historyKey = "HexpadFindSearchHistory"
    private let matchCaseKey = FindBar.matchCaseDefaultsKey
    private var keybindingDirectory: URL!
    private var savedHistory: Any?
    private var savedMatchCase: Any?

    override func setUpWithError() throws {
        try super.setUpWithError()
        let defaults = UserDefaults.standard
        // A developer's real history or match-case preference would change the
        // seeded query / counts below. Save and restore the values verbatim.
        savedHistory = defaults.object(forKey: historyKey)
        savedMatchCase = defaults.object(forKey: matchCaseKey)
        defaults.removeObject(forKey: historyKey)
        defaults.removeObject(forKey: matchCaseKey)

        keybindingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hexpad-findbar-coverage-\(UUID().uuidString)")
        KeybindingStore.overrideDirectory = keybindingDirectory
    }

    override func tearDownWithError() throws {
        let defaults = UserDefaults.standard
        if let savedHistory {
            defaults.set(savedHistory, forKey: historyKey)
        } else {
            defaults.removeObject(forKey: historyKey)
        }
        if let savedMatchCase {
            defaults.set(savedMatchCase, forKey: matchCaseKey)
        } else {
            defaults.removeObject(forKey: matchCaseKey)
        }
        KeybindingStore.overrideDirectory = nil
        if let keybindingDirectory {
            try? FileManager.default.removeItem(at: keybindingDirectory)
        }
        try super.tearDownWithError()
    }

    @discardableResult
    private func makeController() -> MainWindowController {
        let window = MainWindow()
        let controller = MainWindowController(window: window)
        window.contentViewController = controller
        _ = controller.view // loadView + viewDidLoad creates the first tab and find bar
        return controller
    }

    private func openBar(_ controller: MainWindowController, text: String) throws -> FindBar {
        let doc = try XCTUnwrap(controller.tabStore.selectedDocument)
        doc.replaceAllText(with: text)
        let bar = try XCTUnwrap(controller.findBar)
        if !bar.isVisible {
            controller.toggleFindBar()
        }
        return bar
    }

    private func button(_ title: String, in bar: FindBar,
                        file: StaticString = #filePath, line: UInt = #line) throws -> NSButton {
        try XCTUnwrap(bar.subviews.compactMap { $0 as? NSButton }.first { $0.title == title },
                      file: file, line: line)
    }

    private func replaceField(in bar: FindBar) throws -> NSSearchField {
        try XCTUnwrap(bar.subviews.compactMap { $0 as? NSSearchField }
            .first { $0.placeholderString == "Replace..." })
    }

    private func setQuery(_ query: String, replacement: String? = nil, on bar: FindBar) throws {
        bar.searchField.stringValue = query
        if let replacement {
            let field = try replaceField(in: bar)
            field.stringValue = replacement
        }
        bar.performFind()
    }

    // MARK: - 1. Show / hide state machine

    func testShowUnhidesBarAndSeedsTheLastQuery() throws {
        UserDefaults.standard.set(["needle", "older"], forKey: historyKey)
        let controller = makeController()
        let doc = try XCTUnwrap(controller.tabStore.selectedDocument)
        doc.replaceAllText(with: "needle here")
        let bar = try XCTUnwrap(controller.findBar)
        XCTAssertFalse(bar.isVisible)
        XCTAssertTrue(bar.isHidden)

        controller.toggleFindBar()

        XCTAssertTrue(bar.isVisible)
        XCTAssertFalse(bar.isHidden)
        XCTAssertEqual(bar.searchField.stringValue, "needle", "reopening seeds the newest query")
        XCTAssertEqual(bar.matchCountLabel.stringValue, "1 of 1",
                       "the seeded query is searched immediately")
    }

    func testHideCommitsHistoryClearsHighlightsAndPostsFindBarClosed() throws {
        let controller = makeController()
        let bar = try openBar(controller, text: "needle needle")
        try setQuery("needle", on: bar)
        let textView = try XCTUnwrap(controller.editorTextView)
        let layoutManager = try XCTUnwrap(textView.layoutManager)
        XCTAssertNotNil(layoutManager.temporaryAttribute(.backgroundColor,
                                                         atCharacterIndex: 0,
                                                         effectiveRange: nil),
                        "an open bar paints the matches")

        var closes = 0
        let token = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("FindBarClosed"), object: nil, queue: nil
        ) { _ in closes += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        bar.hide()

        XCTAssertFalse(bar.isVisible)
        XCTAssertTrue(bar.isHidden)
        XCTAssertEqual(closes, 1, "closing posts exactly one FindBarClosed")
        XCTAssertEqual(UserDefaults.standard.stringArray(forKey: historyKey), ["needle"])
        XCTAssertNil(layoutManager.temporaryAttribute(.backgroundColor,
                                                      atCharacterIndex: 0,
                                                      effectiveRange: nil),
                     "closing drops the temporary match highlights")
    }

    /// The historical Cmd+F defect: the custom flag and AppKit's isHidden
    /// diverged after the first close because the view was removed and never
    /// re-added. The bar now stays in the hierarchy and only flips two flags.
    func testVisibilityFlagNeverDivergesAcrossRepeatedToggles() throws {
        let controller = makeController()
        let bar = try XCTUnwrap(controller.findBar)
        for _ in 0..<6 {
            controller.toggleFindBar()
            XCTAssertEqual(bar.isVisible, !bar.isHidden,
                           "the custom flag and AppKit state must never disagree")
            XCTAssertNotNil(bar.superview, "the bar is never removed from the hierarchy")
        }
        XCTAssertFalse(bar.isVisible, "an even number of toggles closes the bar")
    }

    // MARK: - 2. Query history

    func testHistoryIsNewestFirstDeduplicatedAndCapped() throws {
        let controller = makeController()
        let bar = try openBar(controller, text: "x")

        for index in 0..<12 {
            bar.searchField.stringValue = "q\(index)"
            bar.hide()
        }
        let history = try XCTUnwrap(UserDefaults.standard.stringArray(forKey: historyKey))
        XCTAssertEqual(history, (2...11).reversed().map { "q\($0)" },
                       "newest first, oldest dropped at the 10-entry cap")

        // Reopening with "q11" in the field and closing again must not duplicate it.
        bar.show()
        XCTAssertEqual(bar.searchField.stringValue, "q11")
        bar.hide()
        let after = try XCTUnwrap(UserDefaults.standard.stringArray(forKey: historyKey))
        XCTAssertEqual(after.count, 10, "the cap survives a repeat commit")
        XCTAssertEqual(after.filter { $0 == "q11" }.count, 1, "a repeat query dedupes")
    }

    func testHistoryUpDownNavigationInTheSearchField() throws {
        UserDefaults.standard.set(["newest", "middle", "oldest"], forKey: historyKey)
        let controller = makeController()
        let bar = try openBar(controller, text: "nothing")
        let textView = try XCTUnwrap(controller.editorTextView)
        XCTAssertEqual(bar.searchField.stringValue, "newest", "show seeds the newest entry")

        // Deleting the seeded text leaves the field empty: the delegate's
        // Up/Down hook then walks the recent queries.
        bar.searchField.stringValue = ""
        let up = #selector(NSResponder.moveUp(_:))
        let down = #selector(NSResponder.moveDown(_:))
        func arrow(_ selector: Selector) {
            _ = bar.control(bar.searchField, textView: textView, doCommandBy: selector)
        }

        arrow(up)
        XCTAssertEqual(bar.searchField.stringValue, "newest")
        arrow(up)
        XCTAssertEqual(bar.searchField.stringValue, "middle")
        arrow(up)
        XCTAssertEqual(bar.searchField.stringValue, "oldest")
        arrow(up)
        XCTAssertEqual(bar.searchField.stringValue, "oldest", "Up stops at the oldest entry")
        arrow(down)
        XCTAssertEqual(bar.searchField.stringValue, "middle")
        arrow(down)
        XCTAssertEqual(bar.searchField.stringValue, "newest")
        arrow(down)
        XCTAssertEqual(bar.searchField.stringValue, "", "Down past the newest clears the field")
    }

    // MARK: - 3. Option flags reaching performFind

    func testRegexModeToggleSwitchesMatchesThenRestoresLiteral() throws {
        let controller = makeController()
        let bar = try openBar(controller, text: "cat cot cut")
        try setQuery("c.t", on: bar)
        XCTAssertEqual(bar.matchCountLabel.stringValue, "No matches",
                       "literal mode treats the dot as a dot")

        let regex = try button("Regex", in: bar)
        let literal = try button("Literal", in: bar)
        regex.performClick(nil)
        XCTAssertEqual(bar.matchCountLabel.stringValue, "1 of 3",
                       "regex mode reaches SearchEngine through performFind")
        XCTAssertEqual(regex.state, .on)
        XCTAssertEqual(literal.state, .off, "the mode buttons are a radio group")

        literal.performClick(nil)
        XCTAssertEqual(bar.matchCountLabel.stringValue, "No matches",
                       "returning to literal clears the regex option")
        XCTAssertEqual(regex.state, .off)
    }

    func testWholeWordToggleNarrowsAndRestoresMatches() throws {
        let controller = makeController()
        let bar = try openBar(controller, text: "cat catalog cat")
        try setQuery("cat", on: bar)
        XCTAssertEqual(bar.matchCountLabel.stringValue, "1 of 3")

        let wholeWord = try button("Whole Word", in: bar)
        wholeWord.performClick(nil)
        XCTAssertEqual(bar.matchCountLabel.stringValue, "1 of 2",
                       "whole word skips the occurrence inside catalog")
        wholeWord.performClick(nil)
        XCTAssertEqual(bar.matchCountLabel.stringValue, "1 of 3",
                       "turning it off releases the option")
    }

    /// The captured scope must survive the bar selecting matches inside it;
    /// otherwise the second find would search only the first match's range.
    func testInSelectionCapturesScopeWithoutShrinkingToTheBarSelection() throws {
        let controller = makeController()
        let bar = try openBar(controller, text: "alpha x alpha x alpha")
        try setQuery("alpha", on: bar)
        XCTAssertEqual(bar.matchCountLabel.stringValue, "1 of 3")
        let textView = try XCTUnwrap(controller.editorTextView)

        // The user (not the bar) broadens the selection to the first two hits.
        textView.setSelectedRange(NSRange(location: 0, length: 13))
        try button("Selection", in: bar).performClick(nil)
        XCTAssertEqual(bar.matchCountLabel.stringValue, "1 of 2",
                       "Selection restricts the search to the captured range")

        bar.findNext()
        XCTAssertEqual(bar.matchCountLabel.stringValue, "2 of 2")
        XCTAssertEqual(textView.selectedRange, NSRange(location: 8, length: 5))
        bar.findNext()
        XCTAssertEqual(bar.matchCountLabel.stringValue, "1 of 2", "navigation wraps inside the scope")

        bar.performFind()
        XCTAssertEqual(bar.matchCountLabel.stringValue, "1 of 2",
                       "the bar's own selection must not become the new scope")

        try button("Selection", in: bar).performClick(nil)
        XCTAssertEqual(bar.matchCountLabel.stringValue, "1 of 3",
                       "turning Selection off searches the whole buffer again")
    }

    func testWrapToggleStopsAtTheEndAndResumesAfterReenabling() throws {
        let controller = makeController()
        let bar = try openBar(controller, text: "hit hit hit")
        try setQuery("hit", on: bar)
        let textView = try XCTUnwrap(controller.editorTextView)
        bar.findNext()
        bar.findNext()
        XCTAssertEqual(bar.matchCountLabel.stringValue, "3 of 3")
        let lastMatch = textView.selectedRange

        let wrap = try button("Wrap", in: bar)
        XCTAssertEqual(wrap.state, .on, "wrap starts on")
        wrap.performClick(nil)
        XCTAssertEqual(wrap.state, .off)
        bar.findNext()
        XCTAssertEqual(bar.matchCountLabel.stringValue, "3 of 3",
                       "with wrap off the last match is the end of the road")
        XCTAssertEqual(textView.selectedRange, lastMatch)

        bar.findPrevious()
        XCTAssertEqual(bar.matchCountLabel.stringValue, "2 of 3")
        wrap.performClick(nil)
        bar.findNext()
        bar.findNext()
        XCTAssertEqual(bar.matchCountLabel.stringValue, "1 of 3",
                       "wrap on: navigation returns to the first match")
    }

    // MARK: - 4. Replace paths

    /// fix1-era defect: single Replace used to use matches[currentMatchIndex]
    /// even when the user had clicked a different matching occurrence.
    func testSingleReplaceTargetsTheUsersMatchingSelection() throws {
        let controller = makeController()
        let doc = try XCTUnwrap(controller.tabStore.selectedDocument)
        let bar = try openBar(controller, text: "one two one two")
        try setQuery("one", replacement: "X", on: bar)
        let textView = try XCTUnwrap(controller.editorTextView)
        XCTAssertEqual(bar.matchCountLabel.stringValue, "1 of 2")

        textView.setSelectedRange(NSRange(location: 8, length: 3)) // the second "one"
        try button("Replace", in: bar).performClick(nil)

        XCTAssertEqual(doc.text, "one two X two", "the selected matching occurrence is replaced")
        XCTAssertEqual(bar.matchCountLabel.stringValue, "1 of 1",
                       "the match list refreshes after the edit")
    }

    func testSingleReplaceFallsBackToCurrentMatchAtACaret() throws {
        let controller = makeController()
        let doc = try XCTUnwrap(controller.tabStore.selectedDocument)
        let bar = try openBar(controller, text: "one two one two")
        try setQuery("one", replacement: "X", on: bar)
        let textView = try XCTUnwrap(controller.editorTextView)

        // A caret is not a match: the current match (index 0 after performFind)
        // is the fallback target.
        textView.setSelectedRange(NSRange(location: 7, length: 0))
        try button("Replace", in: bar).performClick(nil)

        XCTAssertEqual(doc.text, "X two one two")
        XCTAssertEqual(bar.matchCountLabel.stringValue, "1 of 1")
    }

    func testReplaceAllReplacesEveryMatchAndReportsTheCount() throws {
        let controller = makeController()
        let doc = try XCTUnwrap(controller.tabStore.selectedDocument)
        let bar = try openBar(controller, text: "one two one two")
        try setQuery("one", replacement: "X", on: bar)
        let layoutManager = try XCTUnwrap(controller.editorTextView?.layoutManager)

        try button("Replace All", in: bar).performClick(nil)

        XCTAssertEqual(doc.text, "X two X two")
        XCTAssertEqual(bar.matchCountLabel.stringValue, "2 replaced")
        XCTAssertNil(layoutManager.temporaryAttribute(.backgroundColor,
                                                      atCharacterIndex: 0,
                                                      effectiveRange: nil),
                     "no stale highlight survives a replace-all")
    }

    func testRegexReplaceAllHonoursCaptureGroupTemplates() throws {
        let controller = makeController()
        let doc = try XCTUnwrap(controller.tabStore.selectedDocument)
        let bar = try openBar(controller, text: "a1 b22")
        try setQuery("([a-z])(\\d+)", replacement: "$2$1", on: bar)
        try button("Regex", in: bar).performClick(nil)
        XCTAssertEqual(bar.matchCountLabel.stringValue, "1 of 2")

        try button("Replace All", in: bar).performClick(nil)

        XCTAssertEqual(doc.text, "1a 22b", "single and replace-all share the template path")
        XCTAssertEqual(bar.matchCountLabel.stringValue, "2 replaced")
    }

    // MARK: - 5. Match navigation

    func testNextAndPrevButtonsWalkMatchesAndUpdateTheCounter() throws {
        let controller = makeController()
        let bar = try openBar(controller, text: "hit x hit x hit")
        try setQuery("hit", on: bar)
        let textView = try XCTUnwrap(controller.editorTextView)
        XCTAssertEqual(textView.selectedRange, NSRange(location: 0, length: 3))

        let next = try button("Next", in: bar)
        let previous = try button("Prev", in: bar)
        next.performClick(nil)
        XCTAssertEqual(bar.matchCountLabel.stringValue, "2 of 3")
        XCTAssertEqual(textView.selectedRange, NSRange(location: 6, length: 3))
        next.performClick(nil)
        XCTAssertEqual(bar.matchCountLabel.stringValue, "3 of 3")
        XCTAssertEqual(textView.selectedRange, NSRange(location: 12, length: 3))
        next.performClick(nil)
        XCTAssertEqual(bar.matchCountLabel.stringValue, "1 of 3", "Next wraps")
        previous.performClick(nil)
        XCTAssertEqual(bar.matchCountLabel.stringValue, "3 of 3", "Prev wraps the other way")
        XCTAssertEqual(textView.selectedRange, NSRange(location: 12, length: 3))
        previous.performClick(nil)
        XCTAssertEqual(bar.matchCountLabel.stringValue, "2 of 3")
    }

    // MARK: - 6. Delegate seam + document observer

    /// The field editor consumes Enter before keyDown reaches the bar, so the
    /// NSSearchFieldDelegate is the reliable hook for the typed-into case.
    func testSearchFieldDelegateEnterAdvancesAndCommitsHistory() throws {
        let controller = makeController()
        let bar = try openBar(controller, text: "hit hit")
        try setQuery("hit", on: bar)
        let textView = try XCTUnwrap(controller.editorTextView)
        XCTAssertEqual(bar.matchCountLabel.stringValue, "1 of 2")

        let consumed = bar.control(bar.searchField, textView: textView,
                                   doCommandBy: #selector(NSResponder.insertNewline(_:)))

        XCTAssertTrue(consumed, "Enter belongs to the find bar, not the field editor")
        XCTAssertEqual(bar.matchCountLabel.stringValue, "2 of 2")
        XCTAssertEqual(textView.selectedRange, NSRange(location: 4, length: 3))
        XCTAssertEqual(UserDefaults.standard.stringArray(forKey: historyKey), ["hit"],
                       "the delegate commits the query before navigating")
    }

    func testEscapeThroughCancelOperationHidesAndClearsHighlights() throws {
        let controller = makeController()
        let bar = try openBar(controller, text: "hit hit")
        try setQuery("hit", on: bar)
        let layoutManager = try XCTUnwrap(controller.editorTextView?.layoutManager)
        XCTAssertNotNil(layoutManager.temporaryAttribute(.backgroundColor,
                                                         atCharacterIndex: 0,
                                                         effectiveRange: nil))

        bar.cancelOperation(nil)

        XCTAssertFalse(bar.isVisible)
        XCTAssertTrue(bar.isHidden)
        XCTAssertNil(layoutManager.temporaryAttribute(.backgroundColor,
                                                      atCharacterIndex: 0,
                                                      effectiveRange: nil))
    }

    /// The observer is synchronous on the main queue: a programmatic edit
    /// recomputes the count but must not yank the caret to a match (find uses
    /// select: false). Its `isFinding` guard keeps successive notices from
    /// re-entering the search while one is already running.
    func testDocumentChangeRefreshesCountWithoutMovingTheCaret() throws {
        let controller = makeController()
        let doc = try XCTUnwrap(controller.tabStore.selectedDocument)
        let bar = try openBar(controller, text: "hit hit")
        try setQuery("hit", on: bar)
        XCTAssertEqual(bar.matchCountLabel.stringValue, "1 of 2")
        let textView = try XCTUnwrap(controller.editorTextView)
        textView.setSelectedRange(NSRange(location: 4, length: 0))

        // Insert after the caret so the edit itself does not move it.
        doc.replaceCharacters(in: NSRange(location: 7, length: 0), with: " hit")

        XCTAssertEqual(bar.matchCountLabel.stringValue, "1 of 3",
                       "the observer recomputes live counts")
        XCTAssertEqual(textView.selectedRange, NSRange(location: 4, length: 0),
                       "live recount must not steal the caret")
    }

    func testHiddenBarSkipsDocumentChangeWorkUntilShownAgain() throws {
        let controller = makeController()
        let doc = try XCTUnwrap(controller.tabStore.selectedDocument)
        let bar = try openBar(controller, text: "hit hit")
        try setQuery("hit", on: bar)
        XCTAssertEqual(bar.matchCountLabel.stringValue, "1 of 2")
        let textView = try XCTUnwrap(controller.editorTextView)
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        bar.hide()

        doc.replaceCharacters(in: NSRange(location: 7, length: 0), with: " hit")

        XCTAssertEqual(bar.matchCountLabel.stringValue, "1 of 2",
                       "a hidden bar ignores document change notifications")
        XCTAssertEqual(textView.selectedRange.location, 0)

        bar.show()
        XCTAssertEqual(bar.matchCountLabel.stringValue, "1 of 3",
                       "reopening re-searches the current buffer")
    }

    /// The bar listens to two named notifications only. Observing forName: nil
    /// used to catch its own selection notices and recurse into performFind.
    /// With an off-match caret, any unwanted re-find would immediately select
    /// a match, so a burst of unrelated notices is observable here.
    func testUnrelatedNotificationsDoNotTriggerAReentrantFind() throws {
        let controller = makeController()
        let bar = try openBar(controller, text: "hit hit")
        try setQuery("hit", on: bar)
        let textView = try XCTUnwrap(controller.editorTextView)
        textView.setSelectedRange(NSRange(location: 3, length: 0)) // the space between hits

        for index in 0..<50 {
            NotificationCenter.default.post(name: NSNotification.Name("hexpad.unrelated.\(index)"),
                                            object: nil)
        }

        XCTAssertEqual(textView.selectedRange, NSRange(location: 3, length: 0),
                       "only the two named notifications may re-run find")
        XCTAssertEqual(bar.matchCountLabel.stringValue, "1 of 2")
    }
}
