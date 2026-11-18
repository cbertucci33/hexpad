import XCTest
import AppKit
import HexpadKit
@testable import Hexpad

/// P17g-1: Search > Multi-select menu wiring, validation and end-to-end
/// controller behavior. The menu items mirror the token-style group (nil
/// target, registry identifier in `representedObject`), while the commands
/// themselves run through the live editor's caret model.
final class MultiSelectMenuTests: XCTestCase {

    private var keybindingDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        UserDefaults.standard.removeObject(forKey: "HexpadFindSearchHistory")
        UserDefaults.standard.removeObject(forKey: "HexpadFindMatchCase")
        keybindingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hexpad-multiselect-tests-\(UUID().uuidString)")
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

    private func setDocument(_ text: String, on controller: MainWindowController) throws {
        try XCTUnwrap(controller.tabStore.selectedDocument).text = text
        // Replacing the buffer leaves the caret at the end; pin it to the top so
        // the Next variants start from a known anchor.
        controller.editorTextView?.setSelectedRange(NSRange(location: 0, length: 0))
    }

    private func setQuery(_ query: String, on controller: MainWindowController) {
        controller.findBar?.searchField.stringValue = query
    }

    private func menuItem(_ identifier: String) -> NSMenuItem {
        let item = NSMenuItem(
            title: identifier,
            action: #selector(MainWindowController.performMultiSelectCommand(withIdentifier:)),
            keyEquivalent: ""
        )
        item.representedObject = identifier
        return item
    }

    @discardableResult
    private func run(_ identifier: String, on controller: MainWindowController) -> Bool {
        controller.performCommand(identifier: identifier)
    }

    private func runNextUntilEnd(_ identifier: String, on controller: MainWindowController) {
        for _ in 0..<8 where run(identifier, on: controller) {}
    }

    // MARK: - Menu wiring

    func testSearchMenuHasMultiSelectItemsWithPinnedTitles() throws {
        let menu = HexpadAppDelegate().buildMainMenu()
        let searchMenu = try XCTUnwrap(menu.item(withTitle: "Search")?.submenu)

        let expected: [(String, String)] = [
            ("select-all-occurrences", "Select All Occurrences"),
            ("multi-select-undo-latest", "Undo Latest Multi-select"),
            ("multi-select-skip-current", "Skip Current and Go to Next")
        ]
        for (identifier, title) in expected {
            let item = try XCTUnwrap(searchMenu.items.first {
                $0.representedObject as? String == identifier
            })
            XCTAssertEqual(item.title, title)
            XCTAssertEqual(item.action,
                           #selector(MainWindowController.performMultiSelectCommand(withIdentifier:)))
            XCTAssertNil(item.target, "nil target routes to the focused window's controller")
        }

        let nextItem = try XCTUnwrap(searchMenu.items.first { $0.title == "Multi-select Next" })
        let modes = try XCTUnwrap(nextItem.submenu)
        XCTAssertEqual(modes.items.map(\.title), ["Ignore Case", "Match Case", "Whole Word"])
        XCTAssertEqual(modes.items.compactMap { $0.representedObject as? String }, [
            "multi-select-next-ignore-case",
            "multi-select-next-match-case",
            "multi-select-next-whole-word"
        ])
        for item in modes.items {
            XCTAssertEqual(item.action,
                           #selector(MainWindowController.performMultiSelectCommand(withIdentifier:)))
            XCTAssertNil(item.target)
        }
    }

    func testMenuIdentifiersAreRegisteredViewCommands() throws {
        let menu = HexpadAppDelegate().buildMainMenu()
        let searchMenu = try XCTUnwrap(menu.item(withTitle: "Search")?.submenu)
        let identifiers = searchMenu.items.compactMap { $0.representedObject as? String }
            + (searchMenu.items.first { $0.title == "Multi-select Next" }?
                .submenu?.items.compactMap { $0.representedObject as? String } ?? [])
        let expected = CommandRegistry.default.multiSelectCommands.map(\.identifier)

        XCTAssertEqual(Set(identifiers), Set(expected))
        for identifier in expected {
            let command = try XCTUnwrap(CommandRegistry.default.command(for: identifier))
            XCTAssertNotNil(command.viewExecute, identifier)
        }
    }

    // MARK: - Validation

    func testValidationRequiresFocusedBufferAndQuery() throws {
        let (controller, _) = makeController()
        let all = menuItem("select-all-occurrences")
        let next = menuItem("multi-select-next-match-case")
        let skip = menuItem("multi-select-skip-current")
        let undo = menuItem("multi-select-undo-latest")

        try setDocument("", on: controller)
        setQuery("foo", on: controller)
        XCTAssertFalse(controller.validateMenuItem(all), "an empty buffer has nothing to select")
        XCTAssertFalse(controller.validateMenuItem(undo))

        try setDocument("foo bar foo", on: controller)
        setQuery("", on: controller)
        XCTAssertFalse(controller.validateMenuItem(all), "no query means no matches")
        XCTAssertFalse(controller.validateMenuItem(next))
        XCTAssertFalse(controller.validateMenuItem(skip))

        setQuery("foo", on: controller)
        XCTAssertTrue(controller.validateMenuItem(all))
        XCTAssertTrue(controller.validateMenuItem(next))
        XCTAssertTrue(controller.validateMenuItem(skip))
        XCTAssertFalse(controller.validateMenuItem(undo), "nothing added yet")

        run("select-all-occurrences", on: controller)
        XCTAssertTrue(controller.validateMenuItem(undo))
    }

    func testValidationDisabledWithoutAnyDocument() throws {
        let (controller, _) = makeController()
        controller.tabStore.closeAll()

        XCTAssertFalse(controller.validateMenuItem(menuItem("select-all-occurrences")))
        XCTAssertFalse(controller.validateMenuItem(menuItem("multi-select-undo-latest")))
    }

    // MARK: - Select All Occurrences

    func testSelectAllOccurrencesSelectsEveryMatchThroughTheSelector() throws {
        let (controller, _) = makeController()
        try setDocument("foo foobar foo", on: controller)
        setQuery("foo", on: controller)

        controller.performMultiSelectCommand(withIdentifier: menuItem("select-all-occurrences"))

        // Whole-word is enforced for word tokens, so "foobar" is skipped.
        XCTAssertEqual(controller.focusedEditor?.multiCaretState.carets, [
            NSRange(location: 0, length: 3),
            NSRange(location: 11, length: 3)
        ])
        XCTAssertEqual(controller.findQuery, "foo", "the find bar remains the query owner")
    }

    func testSelectAllOccurrencesWithNoMatchesIsANoOp() throws {
        let (controller, _) = makeController()
        try setDocument("foo bar", on: controller)
        setQuery("zzz", on: controller)
        let before = try XCTUnwrap(controller.focusedEditor).multiCaretState

        XCTAssertFalse(run("select-all-occurrences", on: controller))
        XCTAssertEqual(controller.focusedEditor?.multiCaretState, before)
    }

    // MARK: - Multi-select Next modes

    func testNextModeVariantsHonourTheirPinnedOptions() throws {
        // "foo foobar Foo": Ignore Case -> 3 matches, Match Case -> 2,
        // Whole Word -> the two whole-word occurrences (0 and 11).
        let cases: [(String, [NSRange])] = [
            ("multi-select-next-ignore-case", [
                NSRange(location: 0, length: 3),
                NSRange(location: 4, length: 3),
                NSRange(location: 11, length: 3)
            ]),
            ("multi-select-next-match-case", [
                NSRange(location: 0, length: 3),
                NSRange(location: 4, length: 3)
            ]),
            ("multi-select-next-whole-word", [
                NSRange(location: 0, length: 3),
                NSRange(location: 11, length: 3)
            ])
        ]
        for (identifier, expected) in cases {
            let (controller, _) = makeController()
            try setDocument("foo foobar Foo", on: controller)
            setQuery("foo", on: controller)

            runNextUntilEnd(identifier, on: controller)

            XCTAssertEqual(controller.focusedEditor?.multiCaretState.carets, expected, identifier)
        }
    }

    func testNextStopsAtDocumentEndWithoutWrapping() throws {
        let (controller, _) = makeController()
        try setDocument("foo bar foo", on: controller)
        setQuery("foo", on: controller)
        run("multi-select-next-ignore-case", on: controller)
        run("multi-select-next-ignore-case", on: controller)
        let atEnd = try XCTUnwrap(controller.focusedEditor).multiCaretState

        XCTAssertFalse(run("multi-select-next-ignore-case", on: controller))
        XCTAssertEqual(controller.focusedEditor?.multiCaretState, atEnd)
    }

    // MARK: - Skip / undo end to end

    func testSkipCurrentAndUndoLatestThroughTheController() throws {
        let (controller, _) = makeController()
        try setDocument("foo bar foo baz foo", on: controller)
        setQuery("foo", on: controller)

        XCTAssertTrue(run("select-all-occurrences", on: controller))
        XCTAssertEqual(controller.focusedEditor?.multiCaretState.carets.count, 3)

        XCTAssertTrue(run("multi-select-undo-latest", on: controller))
        XCTAssertEqual(controller.focusedEditor?.multiCaretState.carets, [
            NSRange(location: 0, length: 3),
            NSRange(location: 8, length: 3)
        ])

        // Skip the middle caret; it must stay excluded even after Undo Latest
        // removes the caret that replaced it.
        XCTAssertTrue(run("multi-select-skip-current", on: controller))
        XCTAssertEqual(controller.focusedEditor?.multiCaretState.carets, [
            NSRange(location: 0, length: 3),
            NSRange(location: 16, length: 3)
        ])
        XCTAssertTrue(run("multi-select-undo-latest", on: controller))
        XCTAssertEqual(controller.focusedEditor?.multiCaretState.carets, [
            NSRange(location: 0, length: 3)
        ])
        XCTAssertTrue(run("multi-select-next-ignore-case", on: controller))
        XCTAssertEqual(controller.focusedEditor?.multiCaretState.carets, [
            NSRange(location: 0, length: 3),
            NSRange(location: 16, length: 3)
        ])
    }

    func testMultiSelectSessionResetsWhenTheDocumentChanges() throws {
        let (controller, _) = makeController()
        try setDocument("foo foo", on: controller)
        setQuery("foo", on: controller)
        XCTAssertTrue(run("select-all-occurrences", on: controller))
        XCTAssertTrue(controller.focusedEditor?.canUndoLatestMultiSelect == true)

        controller.addNewTab()

        XCTAssertFalse(controller.focusedEditor?.canUndoLatestMultiSelect ?? true)
        XCTAssertFalse(run("multi-select-undo-latest", on: controller))
    }
}
