import XCTest
import AppKit
import HexpadKit
@testable import Hexpad

/// P18h: Search > Find All in Current Document / in All Opened Documents.
/// Exercises the FindBar query path, the controller routing, per-file result
/// grouping in the reused results window, and jumping to a hit in the right
/// tab (including the unfocused split group).
final class FindAllTests: XCTestCase {

    private var keybindingDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Menu construction and the find bar read persisted state; keep the
        // developer's real history/preferences out of these tests.
        UserDefaults.standard.removeObject(forKey: "HexpadFindSearchHistory")
        UserDefaults.standard.removeObject(forKey: "HexpadFindMatchCase")
        keybindingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hexpad-find-all-tests-\(UUID().uuidString)")
        KeybindingStore.overrideDirectory = keybindingDirectory
    }

    override func tearDownWithError() throws {
        KeybindingStore.overrideDirectory = nil
        UserDefaults.standard.removeObject(forKey: "HexpadFindSearchHistory")
        UserDefaults.standard.removeObject(forKey: "HexpadFindMatchCase")
        if let keybindingDirectory {
            try? FileManager.default.removeItem(at: keybindingDirectory)
        }
        try super.tearDownWithError()
    }

    private func makeController() -> (controller: MainWindowController, window: MainWindow) {
        let window = MainWindow()
        let controller = MainWindowController(window: window)
        window.contentViewController = controller
        _ = controller.view
        return (controller, window)
    }

    private func setQuery(_ query: String, on controller: MainWindowController) throws -> FindBar {
        let bar = try XCTUnwrap(controller.findBar)
        if !bar.isVisible {
            controller.toggleFindBar()
        }
        bar.searchField.stringValue = query
        bar.performFind()
        return bar
    }

    // MARK: - Current document

    func testFindAllCurrentDocumentGroupsMatchesPerFile() throws {
        let (controller, _) = makeController()
        let doc = try XCTUnwrap(controller.tabStore.selectedDocument)
        doc.text = "one two\none three\nfour"
        _ = try setQuery("one", on: controller)

        controller.findAllInCurrentDocument(nil)

        let results = try XCTUnwrap(controller.searchResultsController)
        XCTAssertEqual(results.documentGroups.count, 1)
        XCTAssertTrue(results.documentGroups[0].document === doc)
        XCTAssertEqual(results.documentResultCount, 2)
        XCTAssertEqual(results.documentGroups[0].matches.map(\.line), [1, 2])
        XCTAssertEqual(results.window?.title, "Search Results")
    }

    func testFindAllCurrentDocumentHonoursMatchCase() throws {
        let (controller, _) = makeController()
        let doc = try XCTUnwrap(controller.tabStore.selectedDocument)
        doc.text = "Hello hello HELLO"
        let bar = try setQuery("hello", on: controller)
        controller.findAllInCurrentDocument(nil)
        XCTAssertEqual(controller.searchResultsController?.documentResultCount, 3)

        // Match Case is a bar flag; the menu action must reuse it.
        let matchCase = try XCTUnwrap(bar.subviews.compactMap { $0 as? NSButton }
            .first { $0.title == "Match Case" })
        matchCase.state = .off
        matchCase.performClick(nil)
        XCTAssertEqual(bar.matchCountLabel.stringValue, "1 of 1")
        controller.findAllInCurrentDocument(nil)
        XCTAssertEqual(controller.searchResultsController?.documentResultCount, 1)
    }

    // MARK: - All opened documents

    func testFindAllAllOpenedCoversBothGroupsAndUntitledBuffers() throws {
        let (controller, _) = makeController()
        let first = try XCTUnwrap(controller.tabStore.selectedDocument)
        first.text = "needle"

        controller.addNewTab()
        let second = try XCTUnwrap(controller.tabStore.selectedDocument)
        second.text = "needle needle"

        controller.openSplitView()
        controller.focusGroup(.secondary)
        controller.addNewTab()
        let untitled = try XCTUnwrap(controller.tabStore.selectedDocument)
        untitled.text = "needle"
        XCTAssertNil(untitled.filePath, "the secondary buffer must be untitled")

        controller.focusGroup(.primary)
        _ = try setQuery("needle", on: controller)
        controller.findAllInAllOpenedDocuments(nil)

        let results = try XCTUnwrap(controller.searchResultsController)
        XCTAssertEqual(results.documentGroups.count, 3)
        XCTAssertEqual(results.documentResultCount, 4)
        XCTAssertEqual(Set(results.documentGroups.map { $0.document.id }),
                       Set([first.id, second.id, untitled.id]))
    }

    func testFindAllAllOpenedOmitsFilesWithoutHits() throws {
        let (controller, _) = makeController()
        let first = try XCTUnwrap(controller.tabStore.selectedDocument)
        first.text = "needle"
        controller.addNewTab()
        let second = try XCTUnwrap(controller.tabStore.selectedDocument)
        second.text = "haystack"

        _ = try setQuery("needle", on: controller)
        controller.findAllInAllOpenedDocuments(nil)

        let results = try XCTUnwrap(controller.searchResultsController)
        XCTAssertEqual(results.documentGroups.count, 1)
        XCTAssertTrue(results.documentGroups[0].document === first)
    }

    func testFindAllAllOpenedWithNoHitsStillShowsResultsWindow() throws {
        let (controller, _) = makeController()
        try XCTUnwrap(controller.tabStore.selectedDocument).text = "haystack"
        _ = try setQuery("needle", on: controller)

        controller.findAllInAllOpenedDocuments(nil)

        let results = try XCTUnwrap(controller.searchResultsController)
        XCTAssertEqual(results.documentGroups.count, 0)
        XCTAssertEqual(results.documentResultCount, 0)
    }

    // MARK: - Jumping back

    func testNavigateToDocumentMatchSwitchesToOwningTab() throws {
        let (controller, _) = makeController()
        let first = try XCTUnwrap(controller.tabStore.selectedDocument)
        first.text = "aaa"
        controller.addNewTab()
        let second = try XCTUnwrap(controller.tabStore.selectedDocument)
        second.text = "xxneedlexx"
        controller.selectTab(at: 0)
        XCTAssertTrue(controller.tabStore.selectedDocument === first)

        let range = (second.text as NSString).range(of: "needle")
        controller.navigateToDocumentMatch(second, range: range)

        XCTAssertTrue(controller.tabStore.selectedDocument === second)
        XCTAssertEqual(controller.editorTextView?.selectedRange, range)
    }

    func testNavigateToDocumentMatchFocusesSplitGroup() throws {
        let (controller, _) = makeController()
        controller.openSplitView()
        controller.focusGroup(.secondary)
        controller.addNewTab()
        let otherGroupDoc = try XCTUnwrap(controller.tabStore.selectedDocument)
        otherGroupDoc.text = "a needle b"
        controller.focusGroup(.primary)
        XCTAssertEqual(controller.focusedGroup, .primary)

        let range = (otherGroupDoc.text as NSString).range(of: "needle")
        controller.navigateToDocumentMatch(otherGroupDoc, range: range)

        XCTAssertEqual(controller.focusedGroup, .secondary)
        XCTAssertTrue(controller.tabStore.selectedDocument === otherGroupDoc)
        XCTAssertEqual(controller.editorTextView?.selectedRange, range)
    }

    // MARK: - Menu wiring and validation

    func testSearchMenuContainsFindAllItems() throws {
        let menu = HexpadAppDelegate().buildMainMenu()
        let searchMenu = try XCTUnwrap(menu.item(withTitle: "Search")?.submenu)

        let current = try XCTUnwrap(searchMenu.items.first {
            $0.action == #selector(MainWindowController.findAllInCurrentDocument(_:))
        })
        XCTAssertEqual(current.title, "Find All in Current Document")
        XCTAssertNil(current.target, "nil target routes to the focused window's controller")

        let opened = try XCTUnwrap(searchMenu.items.first {
            $0.action == #selector(MainWindowController.findAllInAllOpenedDocuments(_:))
        })
        XCTAssertEqual(opened.title, "Find All in All Opened Documents")
        XCTAssertNil(opened.target)
    }

    func testFindAllValidationTracksDocumentPresenceAndText() throws {
        let (controller, _) = makeController()
        let currentItem = NSMenuItem(title: "Find All in Current Document",
                                     action: #selector(MainWindowController.findAllInCurrentDocument(_:)),
                                     keyEquivalent: "")
        let openedItem = NSMenuItem(title: "Find All in All Opened Documents",
                                    action: #selector(MainWindowController.findAllInAllOpenedDocuments(_:)),
                                    keyEquivalent: "")

        let doc = try XCTUnwrap(controller.tabStore.selectedDocument)
        doc.text = ""
        XCTAssertFalse(controller.validateMenuItem(currentItem),
                       "an empty focused buffer has nothing to find")
        XCTAssertTrue(controller.validateMenuItem(openedItem),
                      "the initial empty untitled document still counts as open")

        doc.text = "text"
        XCTAssertTrue(controller.validateMenuItem(currentItem))

        controller.tabStore.closeAll()
        XCTAssertFalse(controller.validateMenuItem(currentItem))
        XCTAssertFalse(controller.validateMenuItem(openedItem),
                       "no open document in either group disables all-opened")
    }

    func testFindAllWithEmptyQueryOpensTheFindBar() throws {
        let (controller, _) = makeController()
        try XCTUnwrap(controller.tabStore.selectedDocument).text = "text"
        let bar = try XCTUnwrap(controller.findBar)
        XCTAssertFalse(bar.isVisible)

        controller.findAllInCurrentDocument(nil)

        XCTAssertTrue(bar.isVisible)
        XCTAssertNil(controller.searchResultsController)
        XCTAssertEqual(controller.view.window?.firstResponder, bar.searchField.currentEditor())
    }

    // MARK: - Result navigation (F4 / Shift+F4)

    /// Builds a two-file document result set (three matches) and returns the
    /// controller plus its results window.
    private func makeResultsWithTwoFiles()
        throws -> (controller: MainWindowController, results: FindInFilesWindowController,
                   first: DocumentModel, second: DocumentModel) {
        let (controller, _) = makeController()
        let first = try XCTUnwrap(controller.tabStore.selectedDocument)
        first.text = "one two\none three"
        controller.addNewTab()
        let second = try XCTUnwrap(controller.tabStore.selectedDocument)
        second.text = "one four"
        _ = try setQuery("one", on: controller)
        controller.findAllInAllOpenedDocuments(nil)
        let results = try XCTUnwrap(controller.searchResultsController)
        return (controller, results, first, second)
    }

    func testNextResultWalksGroupsAndWraps() throws {
        let (controller, results, first, second) = try makeResultsWithTwoFiles()
        XCTAssertEqual(results.navigableResultCount, 3)
        XCTAssertEqual(results.currentResultIndex, -1)

        // First F4: first match of the first file. The group header sits on
        // table row 0, so the selected row must be 1.
        results.nextResult()
        XCTAssertEqual(results.currentResultIndex, 0)
        XCTAssertEqual(results.selectedResultsRow, 1)
        XCTAssertTrue(controller.tabStore.selectedDocument === first)
        XCTAssertEqual(controller.editorTextView?.selectedRange,
                       (first.text as NSString).range(of: "one"))
        XCTAssertEqual(results.statusText, "Result 1 of 3")

        // Second match in the same file.
        let secondHit = (first.text as NSString).range(of: "one",
                                                       options: [], range: NSRange(location: 4,
                                                                                    length: (first.text as NSString).length - 4))
        results.nextResult()
        XCTAssertEqual(results.currentResultIndex, 1)
        XCTAssertTrue(controller.tabStore.selectedDocument === first)
        XCTAssertEqual(controller.editorTextView?.selectedRange, secondHit)
        XCTAssertEqual(results.statusText, "Result 2 of 3")

        // Crosses into the second file's group.
        results.nextResult()
        XCTAssertEqual(results.currentResultIndex, 2)
        XCTAssertEqual(results.selectedResultsRow, 4)
        XCTAssertTrue(controller.tabStore.selectedDocument === second)
        XCTAssertEqual(controller.editorTextView?.selectedRange, NSRange(location: 0, length: 3))
        XCTAssertEqual(results.statusText, "Result 3 of 3")

        // Wrap at the end back to the first result.
        results.nextResult()
        XCTAssertEqual(results.currentResultIndex, 0)
        XCTAssertEqual(results.selectedResultsRow, 1)
        XCTAssertTrue(controller.tabStore.selectedDocument === first)
        XCTAssertEqual(results.statusText, "Result 1 of 3")
    }

    func testPreviousResultWrapsBackwardsAcrossFiles() throws {
        let (controller, results, first, second) = try makeResultsWithTwoFiles()

        // No cursor yet: previous starts at the last result, not the first.
        results.previousResult()
        XCTAssertEqual(results.currentResultIndex, 2)
        XCTAssertTrue(controller.tabStore.selectedDocument === second)
        XCTAssertEqual(results.statusText, "Result 3 of 3")

        results.previousResult()
        XCTAssertEqual(results.currentResultIndex, 1)
        XCTAssertTrue(controller.tabStore.selectedDocument === first)
        XCTAssertEqual(results.statusText, "Result 2 of 3")

        results.previousResult()
        XCTAssertEqual(results.currentResultIndex, 0)
        XCTAssertEqual(results.statusText, "Result 1 of 3")

        // Wrap at the start back to the last result.
        results.previousResult()
        XCTAssertEqual(results.currentResultIndex, 2)
        XCTAssertTrue(controller.tabStore.selectedDocument === second)
        XCTAssertEqual(results.selectedResultsRow, 4)
        XCTAssertEqual(results.statusText, "Result 3 of 3")
    }

    func testFindAllRebuildsNavigationCursor() throws {
        let (_, results, _, _) = try makeResultsWithTwoFiles()
        results.nextResult()
        XCTAssertEqual(results.currentResultIndex, 0)

        // A fresh search must not leave a stale index pointing into the old
        // row list.
        results.showDocumentResults(groups: results.documentGroups, searchDescription: "\"one\"")
        XCTAssertEqual(results.currentResultIndex, -1)
        XCTAssertEqual(results.selectedResultsRow, -1)
    }

    func testResultNavigationNoOpsWhenResultsWindowIsAbsent() throws {
        let (controller, _) = makeController()
        controller.nextSearchResult(nil)
        controller.previousSearchResult(nil)
        XCTAssertNil(controller.searchResultsController,
                     "navigation must not create the results window")
    }

    func testResultPassthroughForwardsWhileResultsWindowIsVisible() throws {
        let (controller, results, _, second) = try makeResultsWithTwoFiles()
        XCTAssertTrue(results.window?.isVisible == true)

        controller.nextSearchResult(nil)
        XCTAssertEqual(results.currentResultIndex, 0)

        controller.nextSearchResult(nil)
        controller.nextSearchResult(nil)
        XCTAssertEqual(results.currentResultIndex, 2)
        XCTAssertTrue(controller.tabStore.selectedDocument === second)

        controller.previousSearchResult(nil)
        XCTAssertEqual(results.currentResultIndex, 1)
    }

    func testSearchMenuHasResultNavigationItems() throws {
        let menu = HexpadAppDelegate().buildMainMenu()
        let searchMenu = try XCTUnwrap(menu.item(withTitle: "Search")?.submenu)

        let next = try XCTUnwrap(searchMenu.items.first {
            $0.action == #selector(MainWindowController.nextSearchResult(_:))
        })
        XCTAssertEqual(next.title, "Next Result")
        XCTAssertEqual(next.keyEquivalent, "\u{F707}", "F4, per the Run menu's function-key convention")
        XCTAssertEqual(next.keyEquivalentModifierMask, [])
        XCTAssertNil(next.target, "nil target routes to the focused window's controller")

        let previous = try XCTUnwrap(searchMenu.items.first {
            $0.action == #selector(MainWindowController.previousSearchResult(_:))
        })
        XCTAssertEqual(previous.title, "Previous Result")
        XCTAssertEqual(previous.keyEquivalent, "\u{F707}")
        XCTAssertEqual(previous.keyEquivalentModifierMask, [.shift])
        XCTAssertNil(previous.target)
    }

    func testResultNavigationValidationTracksResultsWindowVisibility() throws {
        let (controller, _) = makeController()
        let item = NSMenuItem(title: "Next Result",
                              action: #selector(MainWindowController.nextSearchResult(_:)),
                              keyEquivalent: "")
        XCTAssertFalse(controller.validateMenuItem(item))

        try XCTUnwrap(controller.tabStore.selectedDocument).text = "text"
        _ = try setQuery("text", on: controller)
        controller.findAllInCurrentDocument(nil)
        let results = try XCTUnwrap(controller.searchResultsController)
        results.showWindow(nil)
        XCTAssertTrue(controller.validateMenuItem(item))
    }
}

// MARK: - S18c-1: Select and Find / Find (Volatile)

extension FindAllTests {

    private func button(named title: String, in bar: FindBar) throws -> NSButton {
        try XCTUnwrap(bar.subviews.compactMap { $0 as? NSButton }
            .first { $0.title == title })
    }

    private func select(_ range: NSRange, on controller: MainWindowController) throws -> NSTextView {
        let textView = try XCTUnwrap(controller.editorTextView)
        textView.setSelectedRange(range)
        return textView
    }

    // MARK: Menu wiring

    func testSearchMenuHasSelectAndFindAndVolatileItemsInNotepadOrder() throws {
        let menu = HexpadAppDelegate().buildMainMenu()
        let searchMenu = try XCTUnwrap(menu.item(withTitle: "Search")?.submenu)
        let titles = searchMenu.items.map(\.title)

        let previousFind = try XCTUnwrap(titles.firstIndex(of: "Find Previous"))
        XCTAssertEqual(Array(titles[(previousFind + 1)...(previousFind + 4)]),
                       ["Select and Find Next",
                        "Select and Find Previous",
                        "Find (Volatile) Next",
                        "Find (Volatile) Previous"],
                       "N++ order, right after the field-driven Find Next/Previous")

        let expected: [(String, Selector)] = [
            ("Select and Find Next", #selector(MainWindowController.selectAndFindNext(_:))),
            ("Select and Find Previous", #selector(MainWindowController.selectAndFindPrevious(_:))),
            ("Find (Volatile) Next", #selector(MainWindowController.findVolatileNext(_:))),
            ("Find (Volatile) Previous", #selector(MainWindowController.findVolatilePrevious(_:))),
        ]
        for (title, action) in expected {
            let item = try XCTUnwrap(searchMenu.items.first { $0.title == title })
            XCTAssertEqual(item.action, action)
            XCTAssertNil(item.target, "nil target routes to the focused window's controller")
            XCTAssertEqual(item.keyEquivalent, "", "N++ assigns no chord to these four")
        }
    }

    // MARK: Select and Find (stateful)

    func testSelectAndFindNextSeedsFindStateAndJumpsToFollowingMatch() throws {
        let (controller, _) = makeController()
        let doc = try XCTUnwrap(controller.tabStore.selectedDocument)
        doc.text = "foo bar foo baz foo"
        let textView = try select(NSRange(location: 0, length: 3), on: controller)

        controller.selectAndFindNext(nil)

        let bar = try XCTUnwrap(controller.findBar)
        XCTAssertEqual(bar.searchField.stringValue, "foo", "the selection becomes the query")
        XCTAssertEqual(textView.selectedRange, NSRange(location: 8, length: 3),
                       "next must skip the occurrence it was invoked from")
        XCTAssertEqual(bar.matchCountLabel.stringValue, "2 of 3")
        XCTAssertEqual(UserDefaults.standard.stringArray(forKey: "HexpadFindSearchHistory")?.first,
                       "foo", "Select and Find commits the query to history")
    }

    func testSelectAndFindPreviousJumpsBackwards() throws {
        let (controller, _) = makeController()
        let doc = try XCTUnwrap(controller.tabStore.selectedDocument)
        doc.text = "foo bar foo baz foo"
        let textView = try select(NSRange(location: 8, length: 3), on: controller)

        controller.selectAndFindPrevious(nil)

        XCTAssertEqual(textView.selectedRange, NSRange(location: 0, length: 3))
        XCTAssertEqual(controller.findBar?.matchCountLabel.stringValue, "1 of 3")
    }

    func testSelectAndFindUsesWordAtCaretWhenSelectionIsEmpty() throws {
        let (controller, _) = makeController()
        let doc = try XCTUnwrap(controller.tabStore.selectedDocument)
        doc.text = "alpha beta alpha"
        let textView = try select(NSRange(location: 2, length: 0), on: controller)

        controller.selectAndFindNext(nil)

        XCTAssertEqual(controller.findBar?.searchField.stringValue, "alpha")
        XCTAssertEqual(textView.selectedRange, NSRange(location: 11, length: 5))
    }

    func testSelectAndFindWrapsWhenTheBarWraps() throws {
        let (controller, _) = makeController()
        let doc = try XCTUnwrap(controller.tabStore.selectedDocument)
        doc.text = "foo bar foo"
        let textView = try select(NSRange(location: 8, length: 3), on: controller)

        controller.selectAndFindNext(nil)

        XCTAssertEqual(textView.selectedRange, NSRange(location: 0, length: 3),
                       "Wrap is on by default in the bar")
    }

    func testSelectAndFindNoOpsWhenCaretIsOffAWord() throws {
        let (controller, _) = makeController()
        let doc = try XCTUnwrap(controller.tabStore.selectedDocument)
        doc.text = "alpha  beta"
        // Caret on the second of two spaces: not directly after a word.
        let textView = try select(NSRange(location: 6, length: 0), on: controller)
        let bar = try XCTUnwrap(controller.findBar)

        controller.selectAndFindNext(nil)
        controller.selectAndFindPrevious(nil)

        XCTAssertEqual(textView.selectedRange, NSRange(location: 6, length: 0))
        XCTAssertEqual(bar.searchField.stringValue, "", "nothing was seeded")
        XCTAssertNil(UserDefaults.standard.stringArray(forKey: "HexpadFindSearchHistory"))
    }

    func testSelectAndFindUsesTheBarMode() throws {
        let (controller, _) = makeController()
        let doc = try XCTUnwrap(controller.tabStore.selectedDocument)
        doc.text = "a.b axb"
        // Regex mode: the selected "a.b" is a pattern, so it matches "axb".
        let bar = try setQuery("unused", on: controller)
        try button(named: "Regex", in: bar).performClick(nil)
        let textView = try select(NSRange(location: 0, length: 3), on: controller)

        controller.selectAndFindNext(nil)

        XCTAssertEqual(bar.searchField.stringValue, "a.b")
        XCTAssertEqual(textView.selectedRange, NSRange(location: 4, length: 3))
    }

    // MARK: Find (Volatile) (one-shot)

    func testVolatileFindSelectsNextMatchWithoutTouchingFindState() throws {
        let (controller, _) = makeController()
        let doc = try XCTUnwrap(controller.tabStore.selectedDocument)
        doc.text = "foo bar foo baz foo"
        let bar = try setQuery("bar", on: controller)
        XCTAssertEqual(bar.matchCountLabel.stringValue, "1 of 1")
        let textView = try select(NSRange(location: 0, length: 3), on: controller)

        controller.findVolatileNext(nil)

        XCTAssertEqual(textView.selectedRange, NSRange(location: 8, length: 3),
                       "the next \"foo\", since the selection was the query")
        XCTAssertEqual(bar.searchField.stringValue, "bar", "volatile keeps the old query")
        XCTAssertEqual(bar.matchCountLabel.stringValue, "1 of 1", "and the old match list")
        XCTAssertNil(UserDefaults.standard.stringArray(forKey: "HexpadFindSearchHistory"),
                     "no history entry for the volatile term")

        // The field-driven navigation must still continue from "bar", proving
        // the volatile jump left lastQuery/allMatches alone.
        controller.findNext()
        XCTAssertEqual(textView.selectedRange, (doc.text as NSString).range(of: "bar"))
    }

    func testVolatileFindPreviousJumpsBackwards() throws {
        let (controller, _) = makeController()
        let doc = try XCTUnwrap(controller.tabStore.selectedDocument)
        doc.text = "foo bar foo baz foo"
        _ = try setQuery("bar", on: controller)
        let textView = try select(NSRange(location: 8, length: 3), on: controller)

        controller.findVolatilePrevious(nil)

        XCTAssertEqual(textView.selectedRange, NSRange(location: 0, length: 3))
    }

    func testVolatileFindHonoursBarFlags() throws {
        let (controller, _) = makeController()
        let doc = try XCTUnwrap(controller.tabStore.selectedDocument)
        doc.text = "cat catalog cat"
        let bar = try setQuery("unused", on: controller)
        try button(named: "Whole Word", in: bar).performClick(nil)
        let textView = try select(NSRange(location: 0, length: 3), on: controller)

        controller.findVolatileNext(nil)

        XCTAssertEqual(textView.selectedRange, NSRange(location: 12, length: 3),
                       "whole word skips the occurrence inside \"catalog\"")
    }

    func testVolatileFindUsesTheBarMode() throws {
        let (controller, _) = makeController()
        let doc = try XCTUnwrap(controller.tabStore.selectedDocument)
        doc.text = "a.b axb"
        let bar = try setQuery("unused", on: controller)
        try button(named: "Regex", in: bar).performClick(nil)
        let textView = try select(NSRange(location: 0, length: 3), on: controller)

        controller.findVolatileNext(nil)

        XCTAssertEqual(textView.selectedRange, NSRange(location: 4, length: 3),
                       "the selected text is used as a regex in Regex mode")
        XCTAssertEqual(bar.searchField.stringValue, "unused")
    }

    func testVolatileFindNoOpsWhenCaretIsOffAWord() throws {
        let (controller, _) = makeController()
        let doc = try XCTUnwrap(controller.tabStore.selectedDocument)
        doc.text = "alpha  beta"
        _ = try setQuery("alpha", on: controller)
        let textView = try select(NSRange(location: 6, length: 0), on: controller)

        controller.findVolatileNext(nil)
        controller.findVolatilePrevious(nil)

        XCTAssertEqual(textView.selectedRange, NSRange(location: 6, length: 0))
    }
}

// MARK: - S18e-2: result-group folding

extension FindAllTests {

    func testGroupFoldTogglesVisibleRowsAndHeaderCount() throws {
        let (_, results, _, _) = try makeResultsWithTwoFiles()
        XCTAssertEqual(results.navigableResultCount, 3)
        XCTAssertFalse(results.isGroupFolded(1))
        XCTAssertTrue(results.headerText(for: 1)?.hasSuffix("1 match(es)") == true)

        results.toggleGroupFold(at: 1)

        XCTAssertTrue(results.isGroupFolded(1))
        XCTAssertEqual(results.navigableResultCount, 2,
                       "the folded group's match row leaves the visible row list")
        XCTAssertTrue(results.headerText(for: 1)?.hasSuffix("1 matches") == true,
                      "a folded header reports its hidden match count")
        XCTAssertTrue(results.headerText(for: 1)?.hasPrefix("▸") == true)

        results.toggleGroupFold(at: 1)

        XCTAssertFalse(results.isGroupFolded(1))
        XCTAssertEqual(results.navigableResultCount, 3)
        XCTAssertTrue(results.headerText(for: 1)?.hasSuffix("1 match(es)") == true)
        XCTAssertTrue(results.headerText(for: 1)?.hasPrefix("▾") == true)
    }

    func testNavigationSkipsFoldedGroupAndWrapsOverVisibleRowsOnly() throws {
        let (controller, results, first, _) = try makeResultsWithTwoFiles()
        results.toggleGroupFold(at: 1)
        XCTAssertEqual(results.navigableResultCount, 2)

        // Rows now: header 0, match (0,0), match (0,1), header 1. The folded
        // group's match row (old row 4) must never be selected.
        results.nextResult()
        XCTAssertEqual(results.currentResultIndex, 0)
        XCTAssertEqual(results.selectedResultsRow, 1)
        results.nextResult()
        XCTAssertEqual(results.currentResultIndex, 1)
        XCTAssertEqual(results.selectedResultsRow, 2)

        // Wrapping goes back to the first visible match, not the folded row.
        results.nextResult()
        XCTAssertEqual(results.currentResultIndex, 0)
        XCTAssertEqual(results.selectedResultsRow, 1)
        XCTAssertTrue(controller.tabStore.selectedDocument === first)
        XCTAssertEqual(results.statusText, "Result 1 of 2")
    }

    func testFoldingFirstGroupKeepsSecondGroupsHeaderAdjacent() throws {
        let (controller, results, _, second) = try makeResultsWithTwoFiles()
        results.toggleGroupFold(at: 0)
        XCTAssertEqual(results.navigableResultCount, 1)

        // Rows now: header 0, header 1, match (1,0).
        results.nextResult()
        XCTAssertEqual(results.selectedResultsRow, 2)
        XCTAssertTrue(controller.tabStore.selectedDocument === second)
        XCTAssertEqual(results.statusText, "Result 1 of 1")
    }
}

// MARK: - S18c-2: Incremental Search

extension FindAllTests {

    private func openIncrementalSearch(_ controller: MainWindowController) throws -> IncrementalSearchBar {
        controller.toggleIncrementalSearch(nil)
        let bar = try XCTUnwrap(controller.incrementalSearchBar)
        XCTAssertTrue(bar.isVisible)
        return bar
    }

    func testIncrementalBarKeepsFindBarQueryAndHistoryUntouched() throws {
        let (controller, _) = makeController()
        let doc = try XCTUnwrap(controller.tabStore.selectedDocument)
        doc.text = "foo bar foo"
        let find = try setQuery("bar", on: controller)
        XCTAssertEqual(find.matchCountLabel.stringValue, "1 of 1")
        let historyBefore = UserDefaults.standard.stringArray(forKey: "HexpadFindSearchHistory")

        let bar = try openIncrementalSearch(controller)
        bar.searchField.stringValue = "foo"
        bar.performSearch()

        XCTAssertEqual(bar.matches.count, 2)
        XCTAssertEqual(find.searchField.stringValue, "bar",
                       "incremental search never rewrites the Find field")
        XCTAssertEqual(find.matchCountLabel.stringValue, "1 of 1",
                       "nor its match list/counter")
        XCTAssertEqual(UserDefaults.standard.stringArray(forKey: "HexpadFindSearchHistory"),
                       historyBefore,
                       "nor the shared find history")
        XCTAssertEqual(controller.editorTextView?.selectedRange,
                       (doc.text as NSString).range(of: "foo"),
                       "the incremental match is selected in the editor")
    }

    func testIncrementalBarEscapeClosesAndClearsHighlights() throws {
        let (controller, _) = makeController()
        try XCTUnwrap(controller.tabStore.selectedDocument).text = "foo bar foo"
        let bar = try openIncrementalSearch(controller)
        bar.searchField.stringValue = "foo"
        bar.performSearch()

        let textView = try XCTUnwrap(controller.editorTextView)
        let layoutManager = try XCTUnwrap(textView.layoutManager)
        XCTAssertNotNil(layoutManager.temporaryAttribute(.backgroundColor,
                                                          atCharacterIndex: 0,
                                                          effectiveRange: nil),
                        "live query highlights the first match")

        bar.cancelOperation(nil)

        XCTAssertFalse(bar.isVisible)
        XCTAssertEqual(bar.matches.count, 0)
        XCTAssertNil(layoutManager.temporaryAttribute(.backgroundColor,
                                                       atCharacterIndex: 0,
                                                       effectiveRange: nil),
                     "Escape clears the incremental highlights")
    }

    func testIncrementalBarNextAndPreviousWrap() throws {
        let (controller, _) = makeController()
        let doc = try XCTUnwrap(controller.tabStore.selectedDocument)
        doc.text = "foo bar foo"
        let bar = try openIncrementalSearch(controller)
        bar.searchField.stringValue = "foo"
        bar.performSearch()
        XCTAssertEqual(bar.currentMatchIndex, 0)

        bar.findNext()
        XCTAssertEqual(bar.currentMatchIndex, 1)
        XCTAssertEqual(controller.editorTextView?.selectedRange,
                       (doc.text as NSString).range(of: "foo",
                                                     options: [], range: NSRange(location: 4,
                                                                                length: (doc.text as NSString).length - 4)))
        bar.findNext()
        XCTAssertEqual(bar.currentMatchIndex, 0, "wrap at the end")
        bar.findPrevious()
        XCTAssertEqual(bar.currentMatchIndex, 1, "wrap at the start")
    }

    func testIncrementalBarHidesOnTabSwitch() throws {
        let (controller, _) = makeController()
        try XCTUnwrap(controller.tabStore.selectedDocument).text = "foo"
        let bar = try openIncrementalSearch(controller)
        bar.searchField.stringValue = "foo"
        bar.performSearch()
        XCTAssertTrue(bar.isVisible)

        controller.addNewTab()

        XCTAssertFalse(bar.isVisible, "a tab switch invalidates the match ranges")
        XCTAssertEqual(bar.matches.count, 0)
    }

    func testSearchMenuHasIncrementalSearchItem() throws {
        let menu = HexpadAppDelegate().buildMainMenu()
        let searchMenu = try XCTUnwrap(menu.item(withTitle: "Search")?.submenu)
        let item = try XCTUnwrap(searchMenu.items.first {
            $0.action == #selector(MainWindowController.toggleIncrementalSearch(_:))
        })
        XCTAssertEqual(item.title, "Incremental Search")
        XCTAssertEqual(item.keyEquivalent, "i")
        XCTAssertEqual(item.keyEquivalentModifierMask, [.command])
        XCTAssertNil(item.target, "nil target routes to the focused window's controller")
    }
}

