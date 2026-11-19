import XCTest
import AppKit
import HexpadKit
@testable import Hexpad

/// Wave 2A gap coverage: Incremental Search missing pieces + Toggle Overwrite.
final class IncrementalSearchGapTests: XCTestCase {

    private var keybindingDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        UserDefaults.standard.removeObject(forKey: "HexpadFindSearchHistory")
        UserDefaults.standard.removeObject(forKey: "HexpadFindMatchCase")
        keybindingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hexpad-incr-gap-\(UUID().uuidString)")
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

    private func openBar(_ controller: MainWindowController, text: String) throws -> IncrementalSearchBar {
        let doc = try XCTUnwrap(controller.tabStore.selectedDocument)
        doc.text = text
        controller.toggleIncrementalSearch(nil)
        let bar = try XCTUnwrap(controller.incrementalSearchBar)
        XCTAssertTrue(bar.isVisible)
        return bar
    }

    // MARK: - Counter math

    func testCounterUpdatesOnNavigation() throws {
        let (controller, _) = makeController()
        let bar = try openBar(controller, text: "foo bar foo baz foo")
        bar.searchField.stringValue = "foo"
        bar.performSearch()
        XCTAssertEqual(bar.matches.count, 3)
        XCTAssertEqual(bar.matchCountLabel.stringValue, "1/3")

        bar.findNext()
        XCTAssertEqual(bar.currentMatchIndex, 1)
        XCTAssertEqual(bar.matchCountLabel.stringValue, "2/3")

        bar.findNext()
        XCTAssertEqual(bar.currentMatchIndex, 2)
        XCTAssertEqual(bar.matchCountLabel.stringValue, "3/3")

        bar.findNext()
        XCTAssertEqual(bar.currentMatchIndex, 0)
        XCTAssertEqual(bar.matchCountLabel.stringValue, "1/3")
    }

    // MARK: - Wrap message

    func testWrapMessageOnPastEndNavigation() throws {
        let (controller, _) = makeController()
        let bar = try openBar(controller, text: "foo bar foo")
        bar.searchField.stringValue = "foo"
        bar.performSearch()
        bar.findNext() // 0 -> 1
        bar.findNext() // 1 -> 0 (wrap)
        XCTAssertEqual(bar.wrapLabel.stringValue, "Wrapped to top")

        bar.findPrevious() // 0 -> 1 (wrap backward)
        XCTAssertEqual(bar.wrapLabel.stringValue, "Wrapped to bottom")
    }

    // MARK: - Match case

    func testMatchCaseCheckboxFiltersMatches() throws {
        let (controller, _) = makeController()
        let bar = try openBar(controller, text: "foo Foo FOO")
        bar.searchField.stringValue = "foo"
        bar.performSearch()
        XCTAssertEqual(bar.matches.count, 3, "case-insensitive by default")

        bar.matchCaseButton.state = .on
        bar.matchCaseButton.performClick(nil)
        XCTAssertEqual(bar.matches.count, 1, "match case filters to exact casing")
    }

    // MARK: - Highlight all / Count toggles exist

    func testHighlightAllAndCountCheckboxesToggle() throws {
        let (controller, _) = makeController()
        let bar = try openBar(controller, text: "foo foo")
        bar.searchField.stringValue = "foo"
        bar.performSearch()
        XCTAssertNotNil(bar.highlightAllButton)
        XCTAssertNotNil(bar.countButton)
        bar.countButton.state = .off
        bar.countButton.performClick(nil)
        XCTAssertEqual(bar.matchCountLabel.stringValue, "")
    }

    // MARK: - F3

    func testF3MovesToNextMatch() throws {
        let (controller, _) = makeController()
        let bar = try openBar(controller, text: "foo bar foo")
        bar.searchField.stringValue = "foo"
        bar.performSearch()
        XCTAssertEqual(bar.currentMatchIndex, 0)
        let event = NSEvent.keyEvent(with: .keyDown,
                                     location: .zero,
                                     modifierFlags: [],
                                     timestamp: 0,
                                     windowNumber: 0,
                                     context: nil,
                                     characters: "",
                                     charactersIgnoringModifiers: "",
                                     isARepeat: false,
                                     keyCode: 99)!
        bar.keyDown(with: event)
        XCTAssertEqual(bar.currentMatchIndex, 1)
    }

    // MARK: - Overwrite toggle

    func testOverwriteToggleFlipsTextViewBehavior() throws {
        let (controller, _) = makeController()
        let textView = try XCTUnwrap(controller.editorTextView as? MultiCaretTextView)
        let editor = try XCTUnwrap(controller.editorContainer)
        XCTAssertFalse(textView.isOverwriteMode)

        editor.toggleOverwriteMode()
        XCTAssertTrue(textView.isOverwriteMode, "container toggle flips text view state")

        textView.toggleOverwriteMode()
        XCTAssertFalse(textView.isOverwriteMode, "text view toggle flips back")

        // Typing behavior: in overwrite mode, insertText replaces the char at caret.
        let doc = try XCTUnwrap(controller.tabStore.selectedDocument)
        doc.text = "abc"
        textView.isOverwriteMode = true
        editor.textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.insertText("Z", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(doc.text, "Zbc", "overwrite replaces instead of inserts")
    }
}