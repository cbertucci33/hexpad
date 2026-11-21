import XCTest
import AppKit
import HexpadKit
@testable import Hexpad

/// Wave 4A: Search Results window upgrades + Show Symbol remainder.
///
/// The results tests use both the real Find All path and a small stub-group
/// model (no search bar, no filesystem) so accumulation, pruning, context-menu
/// actions and jump gestures can be checked as pure row-model behaviour. The
/// symbol tests pin the render-state flags the menu actions flip.
final class SearchResultsUpgradeTests: XCTestCase {

    private var keybindingDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        UserDefaults.standard.removeObject(forKey: "HexpadFindSearchHistory")
        UserDefaults.standard.removeObject(forKey: "HexpadFindMatchCase")
        UserDefaults.standard.removeObject(forKey: MultiCaretTextView.controlCharactersDefaultsKey)
        UserDefaults.standard.removeObject(forKey: MultiCaretTextView.wrapSymbolDefaultsKey)
        keybindingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hexpad-search-results-upgrade-\(UUID().uuidString)")
        KeybindingStore.overrideDirectory = keybindingDirectory
    }

    override func tearDownWithError() throws {
        UserDefaults.standard.removeObject(forKey: MultiCaretTextView.controlCharactersDefaultsKey)
        UserDefaults.standard.removeObject(forKey: MultiCaretTextView.wrapSymbolDefaultsKey)
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
        _ = controller.view
        return controller
    }

    private func setQuery(_ query: String, on controller: MainWindowController) throws {
        let bar = try XCTUnwrap(controller.findBar)
        if !bar.isVisible { controller.toggleFindBar() }
        bar.searchField.stringValue = query
        bar.performFind()
    }

    private func match(_ text: String,
                       location: Int,
                       line: Int = 1,
                       column: Int,
                       context: String) -> DocumentMatch {
        DocumentMatch(range: NSRange(location: location, length: text.utf16.count),
                      text: text, line: line, column: column, context: context)
    }

    private func stubResults(path: String = "/tmp/search-results-upgrade.txt")
        -> (controller: FindInFilesWindowController, doc: DocumentModel, first: NSRange) {
        let results = FindInFilesWindowController()
        let doc = DocumentModel(text: "alpha beta",
                                filePath: URL(fileURLWithPath: path))
        let first = match("alpha", location: 0, column: 1, context: "alpha beta")
        let second = match("beta", location: 6, column: 7, context: "alpha beta")
        results.showDocumentResults(
            groups: [DocumentSearchGroup(document: doc, matches: [first, second])],
            searchDescription: "\"stub\"")
        return (results, doc, first.range)
    }

    // MARK: - Feature 1: accumulating, foldable results

    func testDifferentQueriesAccumulateAsFoldableBatchesWithCounts() throws {
        let controller = makeController()
        let doc = try XCTUnwrap(controller.tabStore.selectedDocument)
        doc.text = "alpha beta alpha"
        try setQuery("alpha", on: controller)
        controller.findAllInCurrentDocument(nil)

        let results = try XCTUnwrap(controller.searchResultsController)
        XCTAssertEqual(results.searchBatches.count, 1)
        XCTAssertEqual(results.documentResultCount, 2)
        XCTAssertEqual(results.navigableResultCount, 2)

        try setQuery("beta", on: controller)
        controller.findAllInCurrentDocument(nil)

        XCTAssertEqual(results.searchBatches.count, 2)
        XCTAssertEqual(results.searchBatches.map(\.description), ["\"alpha\"", "\"beta\""])
        XCTAssertEqual(results.documentResultCount, 3)
        XCTAssertEqual(results.navigableResultCount, 3)
        XCTAssertTrue(results.batchHeaderText(for: 0)?.contains("2 matches") == true)
        XCTAssertTrue(results.batchHeaderText(for: 1)?.contains("1 matches") == true)
        XCTAssertTrue(results.headerText(for: 0)?.contains("2 match(es)") == true)
        XCTAssertTrue(results.headerText(for: 1)?.contains("1 match(es)") == true)

        // Folding a search batch removes its hits from the table and from F4.
        results.toggleBatchFold(at: 0)
        XCTAssertTrue(results.isBatchFolded(0))
        XCTAssertEqual(results.navigableResultCount, 1)
        results.toggleBatchFold(at: 0)
        XCTAssertFalse(results.isBatchFolded(0))
        XCTAssertEqual(results.navigableResultCount, 3)
    }

    func testReRunningTheSameQueryRefreshesItsBatch() throws {
        let controller = makeController()
        let doc = try XCTUnwrap(controller.tabStore.selectedDocument)
        doc.text = "alpha alpha"
        try setQuery("alpha", on: controller)
        controller.findAllInCurrentDocument(nil)
        let results = try XCTUnwrap(controller.searchResultsController)
        XCTAssertEqual(results.documentResultCount, 2)

        // Same query: replace in place (the pre-upgrade contract existing
        // Find All tests rely on), rather than growing a duplicate batch.
        doc.text = "alpha"
        controller.findAllInCurrentDocument(nil)
        XCTAssertEqual(results.searchBatches.count, 1)
        XCTAssertEqual(results.documentResultCount, 1)
        XCTAssertEqual(results.navigableResultCount, 1)
    }

    func testDeletePrunesSelectedHitAndUpdatesHeaders() throws {
        let controller = makeController()
        let doc = try XCTUnwrap(controller.tabStore.selectedDocument)
        doc.text = "x x"
        try setQuery("x", on: controller)
        controller.findAllInCurrentDocument(nil)
        let results = try XCTUnwrap(controller.searchResultsController)

        results.nextResult()
        XCTAssertEqual(results.selectedResultsRow, 1)
        XCTAssertEqual(results.navigableResultCount, 2)

        results.deleteSelectedResult()
        XCTAssertEqual(results.documentResultCount, 1)
        XCTAssertEqual(results.navigableResultCount, 1)
        XCTAssertEqual(results.currentResultIndex, -1)
        XCTAssertTrue(results.headerText(for: 0)?.contains("1 match(es)") == true)
    }

    func testContextMenuCopiesPathAndLineThenRemovesHit() throws {
        // Keep the doc alive for the whole test: results hold it weakly now
        // (BUG8 fix), so the old accidental retain via the tuple no longer
        // exists and a dropped reference would deallocate the buffer mid-test.
        let (results, doc, _) = stubResults()
        _ = doc // retained: weak-ref contract means the test owns the lifetime
        let titles = results.contextMenuTitles
        XCTAssertTrue(titles.contains("Copy Path"))
        XCTAssertTrue(titles.contains("Copy Line"))
        XCTAssertTrue(titles.contains("Remove Hit"))

        results.nextResult() // selects the first match row (header sits at 0)
        XCTAssertEqual(results.selectedResultsRow, 1)
        XCTAssertEqual(results.copyablePath(forRow: 1), "/tmp/search-results-upgrade.txt")
        XCTAssertEqual(results.copyableLine(forRow: 1), "1: alpha beta")

        results.copySelectedPath(nil)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string),
                       "/tmp/search-results-upgrade.txt")
        results.copySelectedLine(nil)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "1: alpha beta")

        results.removeSelectedHit(nil)
        XCTAssertEqual(results.documentResultCount, 1)
        XCTAssertEqual(results.navigableResultCount, 1)
    }

    func testEnterJumpsToSelectedMatchWithoutF7FocusKey() throws {
        let (results, doc, firstRange) = stubResults()
        var jumped: (DocumentModel, NSRange)?
        results.onOpenDocumentMatch = { document, range in jumped = (document, range) }

        results.nextResult()
        XCTAssertTrue(jumped?.0 === doc)
        XCTAssertEqual(jumped?.1, firstRange)

        // Enter on the still-selected row re-jumps. This is the Mac stand-in
        // for N++'s F7-focus gesture; no F-key binding is installed.
        jumped = nil
        results.openSelectedRow()
        XCTAssertTrue(jumped?.0 === doc)
        XCTAssertEqual(jumped?.1, firstRange)
    }

    // MARK: - Feature 2: Show Symbol remainder

    func testControlPictureAndSoftWrapHelpers() {
        XCTAssertEqual(MultiCaretTextView.controlPicture(for: 0x00), "␀")
        XCTAssertEqual(MultiCaretTextView.controlPicture(for: 0x01), "␁")
        XCTAssertEqual(MultiCaretTextView.controlPicture(for: 0x1F), "␟")
        XCTAssertNil(MultiCaretTextView.controlPicture(for: 0x09)) // tab
        XCTAssertNil(MultiCaretTextView.controlPicture(for: 0x0A)) // LF
        XCTAssertNil(MultiCaretTextView.controlPicture(for: 0x0D)) // CR
        XCTAssertNil(MultiCaretTextView.controlPicture(for: 0x20)) // space
        XCTAssertNil(MultiCaretTextView.controlPicture(for: 0x7F)) // outside C0

        let wrapped = "abcdefghij" as NSString
        XCTAssertTrue(MultiCaretTextView.isSoftWrappedFragment(
            charRange: NSRange(location: 0, length: 5), text: wrapped))
        XCTAssertFalse(MultiCaretTextView.isSoftWrappedFragment(
            charRange: NSRange(location: 5, length: 5), text: wrapped)) // last fragment
        let hard = "abc\ndef" as NSString
        XCTAssertFalse(MultiCaretTextView.isSoftWrappedFragment(
            charRange: NSRange(location: 0, length: 4), text: hard)) // ends at LF
    }

    func testSymbolTogglesFlipRenderFlagsAndMenuCheckmarks() throws {
        let controller = makeController()
        let delegate = HexpadAppDelegate()
        delegate.activeControllerOverride = controller
        defer { delegate.activeControllerOverride = nil }

        let textView = try XCTUnwrap(controller.editorTextView as? MultiCaretTextView)
        let showSymbol = try XCTUnwrap(
            HexpadAppDelegate().buildMainMenu()
                .item(withTitle: "View")?.submenu
                .flatMap { $0.item(withTitle: "Show Symbol")?.submenu })
        let controlItem = try XCTUnwrap(
            showSymbol.item(withTitle: "Show Non-Printing Characters"))
        let wrapItem = try XCTUnwrap(showSymbol.item(withTitle: "Show Wrap Symbol"))
        XCTAssertEqual(controlItem.state, .off)
        XCTAssertEqual(wrapItem.state, .off)

        delegate.toggleShowControlCharacters(controlItem)
        XCTAssertTrue(textView.showsControlCharacters)
        XCTAssertEqual(controlItem.state, .on)
        XCTAssertTrue(ShowSymbolExtras.showControlCharacters)

        delegate.toggleShowWrapSymbol(wrapItem)
        XCTAssertTrue(textView.showsWrapSymbol)
        XCTAssertEqual(wrapItem.state, .on)

        delegate.toggleShowControlCharacters(controlItem)
        XCTAssertFalse(textView.showsControlCharacters)
        XCTAssertEqual(controlItem.state, .off)
        XCTAssertFalse(ShowSymbolExtras.showControlCharacters)
        XCTAssertTrue(textView.showsWrapSymbol, "toggles are independent")
    }

    func testPreferencePushDoesNotClobberExtraSymbolFlags() {
        let textView = MultiCaretTextView()
        textView.setExtraSymbolVisibility(showControlCharacters: true, showWrapSymbol: false)
        textView.setSymbolVisibility(showWhitespace: true, showEOL: false,
                                     showIndentGuide: true, tabSize: 2)
        XCTAssertTrue(textView.showsControlCharacters)
        XCTAssertFalse(textView.showsWrapSymbol)
        XCTAssertTrue(textView.showsWhitespace)
        XCTAssertTrue(textView.showsIndentGuide)
    }

    func testShowIndentGuideRendererIsStillWired() {
        let textView = MultiCaretTextView()
        textView.setSymbolVisibility(showWhitespace: false, showEOL: false,
                                     showIndentGuide: true, tabSize: 4)
        XCTAssertTrue(textView.showsIndentGuide)
        // The flag drives the existing dotted-guide pass in drawSymbols, whose
        // column math is pinned here (and in WhitespaceGeometryTests).
        XCTAssertEqual(WhitespaceGeometry.guideColumns(
            forLeadingWhitespace: "        ", tabSize: 4), [4, 8])
        textView.setSymbolVisibility(showWhitespace: false, showEOL: false,
                                     showIndentGuide: false, tabSize: 4)
        XCTAssertFalse(textView.showsIndentGuide)
    }
}
