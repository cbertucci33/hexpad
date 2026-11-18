import XCTest
import AppKit
import HexpadKit
@testable import Hexpad

/// S18e-1: Search > Next Result / Previous Result (F4 / Shift+F4).
///
/// Pins the raw-function-key menu seam and the wrap-around navigation over the
/// results window's flat row model. Navigation is driven through the same
/// `MainWindowController` passthroughs the F4 menu items target, so these tests
/// cover the keybinding seam as well as jump-to-owning-tab activation.
final class SearchResultNavTests: XCTestCase {

    private var keybindingDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Menu construction and the find bar read persisted state; keep the
        // developer's real history/preferences out of these tests.
        UserDefaults.standard.removeObject(forKey: "HexpadFindSearchHistory")
        UserDefaults.standard.removeObject(forKey: "HexpadFindMatchCase")
        keybindingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hexpad-search-result-nav-\(UUID().uuidString)")
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

    private func makeController() -> MainWindowController {
        let window = MainWindow()
        let controller = MainWindowController(window: window)
        window.contentViewController = controller
        _ = controller.view // loadView + viewDidLoad; creates the first tab
        return controller
    }

    /// All UTF-16 ranges of `needle` in `text`, in display order. Group headers
    /// are excluded from the results window's navigation rows, so these are the
    /// exact ranges the jump-to-hit path must select.
    private func matchRanges(of needle: String, in text: String) -> [NSRange] {
        let ns = text as NSString
        var found: [NSRange] = []
        var start = 0
        while start <= ns.length - needle.utf16.count {
            let range = ns.range(of: needle, options: [],
                                 range: NSRange(location: start, length: ns.length - start))
            if range.location == NSNotFound { break }
            found.append(range)
            start = NSMaxRange(range)
        }
        return found
    }

    /// Three tabs in the primary group. "needle" hits twice in the first buffer
    /// and once in each of the other two: four navigation rows, with group
    /// headers sitting between them in the table view.
    private func makeThreeTabFixture() throws -> (
        controller: MainWindowController,
        results: FindInFilesWindowController,
        docs: [DocumentModel],
        ranges: [[NSRange]]
    ) {
        let controller = makeController()
        let texts = ["needle ... needle", "middle needle", "last needle"]
        var docs: [DocumentModel] = []
        for (index, text) in texts.enumerated() {
            if index > 0 { controller.addNewTab() }
            let doc = try XCTUnwrap(controller.tabStore.selectedDocument)
            doc.text = text
            docs.append(doc)
        }

        let bar = try XCTUnwrap(controller.findBar)
        if !bar.isVisible { controller.toggleFindBar() }
        bar.searchField.stringValue = "needle"
        bar.performFind()

        controller.findAllInAllOpenedDocuments(nil)
        let results = try XCTUnwrap(controller.searchResultsController)
        XCTAssertEqual(results.navigableResultCount, 4)
        return (controller, results, docs, docs.map { matchRanges(of: "needle", in: $0.text) })
    }

    // MARK: - Wrap

    func testNextResultWrapsFromLastToFirstAcrossTabs() throws {
        let (controller, results, docs, ranges) = try makeThreeTabFixture()
        XCTAssertEqual(results.currentResultIndex, -1)

        // (cursor, table row, owning doc, match index, status)
        let steps: [(Int, Int, Int, Int, String)] = [
            (0, 1, 0, 0, "Result 1 of 4"),
            (1, 2, 0, 1, "Result 2 of 4"),
            (2, 4, 1, 0, "Result 3 of 4"),
            (3, 6, 2, 0, "Result 4 of 4"),
            (0, 1, 0, 0, "Result 1 of 4"), // wrap at the last result
        ]
        for (index, row, docIndex, matchIndex, status) in steps {
            controller.nextSearchResult(nil)
            XCTAssertEqual(results.currentResultIndex, index)
            XCTAssertEqual(results.selectedResultsRow, row)
            XCTAssertTrue(controller.tabStore.selectedDocument === docs[docIndex],
                          "F4 must activate the hit's owning tab")
            XCTAssertEqual(controller.editorTextView?.selectedRange, ranges[docIndex][matchIndex])
            XCTAssertEqual(results.statusText, status)
        }
    }

    func testPreviousResultWrapsFromFirstToLastAcrossTabs() throws {
        let (controller, results, docs, ranges) = try makeThreeTabFixture()
        XCTAssertEqual(results.currentResultIndex, -1)

        // With no cursor yet, Shift+F4 starts at the last result (N++ style).
        let steps: [(Int, Int, Int, Int, String)] = [
            (3, 6, 2, 0, "Result 4 of 4"),
            (2, 4, 1, 0, "Result 3 of 4"),
            (1, 2, 0, 1, "Result 2 of 4"),
            (0, 1, 0, 0, "Result 1 of 4"),
            (3, 6, 2, 0, "Result 4 of 4"), // wrap at the first result
        ]
        for (index, row, docIndex, matchIndex, status) in steps {
            controller.previousSearchResult(nil)
            XCTAssertEqual(results.currentResultIndex, index)
            XCTAssertEqual(results.selectedResultsRow, row)
            XCTAssertTrue(controller.tabStore.selectedDocument === docs[docIndex])
            XCTAssertEqual(controller.editorTextView?.selectedRange, ranges[docIndex][matchIndex])
            XCTAssertEqual(results.statusText, status)
        }
    }

    func testNavigationWrapsOverVisibleRowsOnlyWhenGroupFolded() throws {
        let (controller, results, docs, ranges) = try makeThreeTabFixture()

        results.toggleGroupFold(at: 0) // first buffer's two hits leave the order
        XCTAssertTrue(results.isGroupFolded(0))
        XCTAssertEqual(results.navigableResultCount, 2)
        XCTAssertEqual(results.currentResultIndex, -1)

        controller.nextSearchResult(nil)
        XCTAssertEqual(results.selectedResultsRow, 2)
        XCTAssertTrue(controller.tabStore.selectedDocument === docs[1])
        XCTAssertEqual(controller.editorTextView?.selectedRange, ranges[1][0])
        XCTAssertEqual(results.statusText, "Result 1 of 2")

        controller.nextSearchResult(nil)
        XCTAssertEqual(results.selectedResultsRow, 4)
        XCTAssertTrue(controller.tabStore.selectedDocument === docs[2])

        controller.nextSearchResult(nil) // wrap skips the folded group entirely
        XCTAssertEqual(results.selectedResultsRow, 2)
        XCTAssertTrue(controller.tabStore.selectedDocument === docs[1])
        XCTAssertEqual(controller.editorTextView?.selectedRange, ranges[1][0])
        XCTAssertEqual(results.statusText, "Result 1 of 2")
    }

    // MARK: - Jump-to-hit across split groups

    func testResultNavigationActivatesOwningTabInUnfocusedSplitGroup() throws {
        let controller = makeController()
        controller.openSplitView()
        controller.focusGroup(.secondary)
        controller.addNewTab()
        let far = try XCTUnwrap(controller.tabStore.selectedDocument)
        far.text = "far needle"

        controller.focusGroup(.primary)
        let near = try XCTUnwrap(controller.tabStore.selectedDocument)
        near.text = "near needle"

        let bar = try XCTUnwrap(controller.findBar)
        if !bar.isVisible { controller.toggleFindBar() }
        bar.searchField.stringValue = "needle"
        bar.performFind()
        controller.findAllInAllOpenedDocuments(nil)
        let results = try XCTUnwrap(controller.searchResultsController)
        XCTAssertEqual(results.navigableResultCount, 2)

        // Primary hit: stays in the focused group.
        controller.nextSearchResult(nil)
        XCTAssertEqual(controller.focusedGroup, .primary)
        XCTAssertTrue(controller.tabStore.selectedDocument === near)
        XCTAssertEqual(controller.editorTextView?.selectedRange,
                       (near.text as NSString).range(of: "needle"))

        // Secondary hit: focus moves to the owning group/tab.
        controller.nextSearchResult(nil)
        XCTAssertEqual(controller.focusedGroup, .secondary)
        XCTAssertTrue(controller.tabStore.selectedDocument === far)
        XCTAssertEqual(controller.editorTextView?.selectedRange,
                       (far.text as NSString).range(of: "needle"))

        // Wrap returns to the primary group.
        controller.nextSearchResult(nil)
        XCTAssertEqual(results.currentResultIndex, 0)
        XCTAssertEqual(controller.focusedGroup, .primary)
        XCTAssertTrue(controller.tabStore.selectedDocument === near)
        XCTAssertEqual(controller.editorTextView?.selectedRange,
                       (near.text as NSString).range(of: "needle"))
    }

    // MARK: - Keybinding seam

    func testF4AndShiftF4MenuItemsUseRawFunctionKeyWithoutCollision() throws {
        let menu = HexpadAppDelegate().buildMainMenu()
        let searchMenu = try XCTUnwrap(menu.item(withTitle: "Search")?.submenu)

        let next = try XCTUnwrap(searchMenu.items.first {
            $0.action == #selector(MainWindowController.nextSearchResult(_:))
        })
        XCTAssertEqual(next.title, "Next Result")
        XCTAssertEqual(next.keyEquivalent, "\u{F707}", "F4 is the raw function key")
        XCTAssertEqual(next.keyEquivalentModifierMask, [])
        XCTAssertNil(next.target, "nil target routes to the focused window's controller")

        let previous = try XCTUnwrap(searchMenu.items.first {
            $0.action == #selector(MainWindowController.previousSearchResult(_:))
        })
        XCTAssertEqual(previous.title, "Previous Result")
        XCTAssertEqual(previous.keyEquivalent, "\u{F707}")
        XCTAssertEqual(previous.keyEquivalentModifierMask, [.shift])
        XCTAssertNil(previous.target)

        // F4 is not claimed by the KeybindingStore default command table (F2
        // and the arrow keys are), so no override/menu chord collides with it.
        XCTAssertFalse(EditorCommandBinding.defaultBindings.contains {
            $0.keyEquivalent == "\u{F707}"
        })
        XCTAssertTrue(KeybindingStore.isFunctionKey("\u{F707}"))
        XCTAssertTrue(KeybindingStore.isUsable(keyEquivalent: "\u{F707}", modifierMask: []))
    }

    func testResultNavigationNoOpsAndValidationWithoutVisibleResults() throws {
        let controller = makeController()
        let nextItem = NSMenuItem(title: "Next Result",
                                  action: #selector(MainWindowController.nextSearchResult(_:)),
                                  keyEquivalent: "")
        let previousItem = NSMenuItem(title: "Previous Result",
                                      action: #selector(MainWindowController.previousSearchResult(_:)),
                                      keyEquivalent: "")
        XCTAssertFalse(controller.validateMenuItem(nextItem))
        XCTAssertFalse(controller.validateMenuItem(previousItem))

        controller.nextSearchResult(nil)
        controller.previousSearchResult(nil)
        XCTAssertNil(controller.searchResultsController,
                     "navigation must not create the results window")

        try XCTUnwrap(controller.tabStore.selectedDocument).text = "needle"
        let bar = try XCTUnwrap(controller.findBar)
        if !bar.isVisible { controller.toggleFindBar() }
        bar.searchField.stringValue = "needle"
        bar.performFind()
        controller.findAllInCurrentDocument(nil)
        let results = try XCTUnwrap(controller.searchResultsController)
        results.showWindow(nil)

        XCTAssertTrue(controller.validateMenuItem(nextItem))
        XCTAssertTrue(controller.validateMenuItem(previousItem))
        controller.nextSearchResult(nil)
        XCTAssertEqual(results.currentResultIndex, 0)
    }
}
