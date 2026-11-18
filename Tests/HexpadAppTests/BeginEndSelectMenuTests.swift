import XCTest
import AppKit
import HexpadKit
@testable import Hexpad

/// P17g-2: Search > Begin/End Select menu wiring, validation and end-to-end
/// controller behavior. The items follow the P17g-1 idiom (nil-targeted, titles
/// from the registry) but use dedicated actions instead of a String
/// `representedObject`, which the P17g-1 menu-shape test pins to its own group.
///
/// N++ parity pins that a user selection change (mouse or keyboard) cancels a
/// pending anchor. Tests that need a moved caret at completion therefore use
/// the editor's own `setMultiCaretState` sync path — the same path a command
/// uses — while `textView.setSelectedRange` models user navigation.
final class BeginEndSelectMenuTests: XCTestCase {

    private var keybindingDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        UserDefaults.standard.removeObject(forKey: "HexpadFindSearchHistory")
        UserDefaults.standard.removeObject(forKey: "HexpadFindMatchCase")
        keybindingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hexpad-begindowntests-\(UUID().uuidString)")
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

    private func makeEditor(_ text: String) -> EditorContainer {
        let editor = EditorContainer()
        editor.bind(to: DocumentModel(text: text))
        return editor
    }

    private func setDocument(_ text: String, on controller: MainWindowController) throws {
        try XCTUnwrap(controller.tabStore.selectedDocument).text = text
        controller.editorTextView?.setSelectedRange(NSRange(location: 0, length: 0))
    }

    private func action(for identifier: String) -> Selector {
        identifier == "begin-end-select-column"
            ? #selector(MainWindowController.beginEndSelectColumn(_:))
            : #selector(MainWindowController.beginEndSelect(_:))
    }

    private func menuItem(_ identifier: String) -> NSMenuItem {
        NSMenuItem(title: identifier, action: action(for: identifier), keyEquivalent: "")
    }

    @discardableResult
    private func run(_ identifier: String, on controller: MainWindowController) -> Bool {
        controller.performCommand(identifier: identifier)
    }

    // MARK: - Menu wiring

    func testSearchMenuHasBothItemsAfterTheMultiSelectGroup() throws {
        let menu = HexpadAppDelegate().buildMainMenu()
        let searchMenu = try XCTUnwrap(menu.item(withTitle: "Search")?.submenu)
        let titles = searchMenu.items.map(\.title)

        let skipIndex = try XCTUnwrap(titles.firstIndex(of: "Skip Current and Go to Next"))
        let beginIndex = try XCTUnwrap(titles.firstIndex(of: "Begin/End Select"))
        let columnIndex = try XCTUnwrap(titles.firstIndex(of: "Begin/End Select in Column Mode"))
        XCTAssertEqual(beginIndex, skipIndex + 2,
                       "Begin/End Select follows the P17g-1 items (one separator between)")
        XCTAssertEqual(columnIndex, beginIndex + 1)

        let expected: [(String, String)] = [
            ("begin-end-select", "Begin/End Select"),
            ("begin-end-select-column", "Begin/End Select in Column Mode")
        ]
        for (identifier, title) in expected {
            let item = try XCTUnwrap(searchMenu.items.first { $0.title == title })
            XCTAssertEqual(item.action, action(for: identifier))
            XCTAssertNil(item.target, "nil target routes to the focused window's controller")
            XCTAssertNil(item.representedObject,
                         "the P17g-1 String-identifier menu test stays pinned to its group")
            let command = try XCTUnwrap(CommandRegistry.default.command(for: identifier))
            XCTAssertEqual(command.title, title)
            XCTAssertNotNil(command.viewExecute)
            XCTAssertTrue(CommandRegistry.default.beginEndSelectCommands.contains {
                $0.identifier == identifier
            })
        }
    }

    // MARK: - Validation

    func testValidationRequiresFocusedNonEmptyBufferButNotAnAnchor() throws {
        let (controller, _) = makeController()
        let begin = menuItem("begin-end-select")
        let column = menuItem("begin-end-select-column")

        try setDocument("", on: controller)
        XCTAssertFalse(controller.validateMenuItem(begin))
        XCTAssertFalse(controller.validateMenuItem(column))

        controller.tabStore.closeAll()
        XCTAssertFalse(controller.validateMenuItem(begin))

        controller.addNewTab()
        try setDocument("abc", on: controller)
        XCTAssertFalse(controller.focusedEditor?.hasPendingBeginEndSelectAnchor ?? true)
        XCTAssertTrue(controller.validateMenuItem(begin),
                      "Begin needs only a focused non-empty buffer")
        XCTAssertTrue(controller.validateMenuItem(column),
                      "the End half with no anchor stays enabled and no-ops (N++ parity)")
    }

    // MARK: - Normal selection

    func testBeginThenCompleteSelectsTheUnionRange() throws {
        let (controller, _) = makeController()
        try setDocument("alpha beta gamma", on: controller)
        let editor = try XCTUnwrap(controller.focusedEditor)

        XCTAssertTrue(run("begin-end-select", on: controller))
        XCTAssertTrue(editor.hasPendingBeginEndSelectAnchor)
        XCTAssertEqual(editor.textView.selectedRange, NSRange(location: 0, length: 0),
                       "anchoring does not move the caret")

        // Move the caret on the editor's own sync path so the anchor survives
        // (a user selection change would cancel it — pinned separately below).
        editor.setMultiCaretState(MultiCaretState(caretAt: 16))
        XCTAssertTrue(editor.hasPendingBeginEndSelectAnchor)

        XCTAssertTrue(run("begin-end-select", on: controller))
        XCTAssertEqual(editor.textView.selectedRange, NSRange(location: 0, length: 16))
        XCTAssertFalse(editor.hasPendingBeginEndSelectAnchor)
    }

    func testCompletionWithAnExistingSelectionUsesItsWholeRange() throws {
        let (controller, _) = makeController()
        try setDocument("0123456789", on: controller)
        let editor = try XCTUnwrap(controller.focusedEditor)

        editor.textView.setSelectedRange(NSRange(location: 2, length: 3))
        XCTAssertTrue(run("begin-end-select", on: controller))
        editor.setMultiCaretState(MultiCaretState(caretAt: 9))

        XCTAssertTrue(run("begin-end-select", on: controller))
        XCTAssertEqual(editor.textView.selectedRange, NSRange(location: 2, length: 7),
                       "the anchored selection's start joins the final caret")
    }

    func testSecondPressWithoutPendingAnchorLeavesTheSelectionAlone() throws {
        let (controller, _) = makeController()
        try setDocument("hello world", on: controller)
        let editor = try XCTUnwrap(controller.focusedEditor)
        let before = editor.textView.selectedRange

        // No anchor is pending, so the End half is a no-op at the editor level:
        // the command runs (and the item stays enabled) but nothing is selected.
        XCTAssertEqual(before, NSRange(location: 0, length: 0))
        editor.performBeginEndSelect(.standard)
        XCTAssertEqual(editor.textView.selectedRange, before,
                       "a press without an anchor only arms the toggle")
        XCTAssertTrue(editor.hasPendingBeginEndSelectAnchor)
    }

    // MARK: - Column mode

    func testColumnModeCompletionUsesTheExistingColumnRepresentation() throws {
        let (controller, _) = makeController()
        try setDocument("abcde\nfghij\nklmno", on: controller)
        let editor = try XCTUnwrap(controller.focusedEditor)

        editor.textView.setSelectedRange(NSRange(location: 1, length: 0))
        XCTAssertTrue(run("begin-end-select-column", on: controller))
        editor.setMultiCaretState(MultiCaretState(caretAt: 14))

        XCTAssertTrue(run("begin-end-select-column", on: controller))

        let expected = ColumnEditing.carets(
            in: "abcde\nfghij\nklmno",
            rectangle: ColumnRectangle(start: TextPoint(line: 0, column: 1),
                                       end: TextPoint(line: 2, column: 2))
        )
        XCTAssertEqual(editor.multiCaretState, expected)
        XCTAssertEqual(editor.multiCaretState.carets, [
            NSRange(location: 1, length: 1),
            NSRange(location: 7, length: 1),
            NSRange(location: 13, length: 1)
        ])
    }

    func testColumnModeRaggedLinesUseColumnEditingClamping() throws {
        let editor = makeEditor("abcde\nx\nklmno")
        editor.textView.setSelectedRange(NSRange(location: 1, length: 0))

        XCTAssertTrue(editor.performBeginEndSelect(.column))
        // "abcde\nx\nklmno": line 2 starts at 8, so column 3 is offset 11.
        editor.setMultiCaretState(MultiCaretState(caretAt: 11))
        XCTAssertTrue(editor.performBeginEndSelect(.column))

        let rectangle = ColumnRectangle(start: TextPoint(line: 0, column: 1),
                                        end: TextPoint(line: 2, column: 3))
        let expected = ColumnEditing.carets(in: "abcde\nx\nklmno", rectangle: rectangle)
        XCTAssertEqual(editor.multiCaretState, expected)
        XCTAssertEqual(editor.multiCaretState.carets, [
            NSRange(location: 1, length: 2),
            NSRange(location: 7, length: 0),
            NSRange(location: 9, length: 2)
        ])
    }

    // MARK: - Cancellation

    func testUnrelatedSelectionChangeCancelsPendingAnchor() throws {
        let (controller, _) = makeController()
        try setDocument("abcdefghij", on: controller)
        let editor = try XCTUnwrap(controller.focusedEditor)

        XCTAssertTrue(run("begin-end-select", on: controller))
        XCTAssertTrue(editor.hasPendingBeginEndSelectAnchor)

        // Mouse / keyboard navigation: any selection change not caused by the
        // command itself drops the anchor (N++ parity).
        editor.textView.setSelectedRange(NSRange(location: 4, length: 0))
        XCTAssertFalse(editor.hasPendingBeginEndSelectAnchor)

        let before = editor.textView.selectedRange
        XCTAssertTrue(run("begin-end-select", on: controller))
        XCTAssertEqual(editor.textView.selectedRange, before,
                       "a press with no anchor only re-anchors; the caret does not move")
        XCTAssertTrue(editor.hasPendingBeginEndSelectAnchor)
    }

    func testAnchorSurvivesUnrelatedViewCommandsUntilCompleted() throws {
        let (controller, _) = makeController()
        try setDocument("foo bar foo", on: controller)
        let editor = try XCTUnwrap(controller.focusedEditor)

        XCTAssertTrue(run("begin-end-select", on: controller))
        // Multi-select changes the caret through the editor's sync path, which
        // is not a user selection change, so the anchor must survive it.
        controller.findBar?.searchField.stringValue = "foo"
        XCTAssertTrue(run("select-all-occurrences", on: controller))
        XCTAssertEqual(editor.textView.selectedRange, NSRange(location: 0, length: 3))
        XCTAssertTrue(editor.hasPendingBeginEndSelectAnchor)

        XCTAssertTrue(run("begin-end-select", on: controller))
        XCTAssertFalse(editor.hasPendingBeginEndSelectAnchor)
    }

    // MARK: - Selector and session behavior

    func testEndToEndThroughTheMenuAction() throws {
        let (controller, _) = makeController()
        try setDocument("hello world", on: controller)
        let editor = try XCTUnwrap(controller.focusedEditor)
        let item = menuItem("begin-end-select")

        XCTAssertTrue(controller.validateMenuItem(item))
        controller.beginEndSelect(item)
        XCTAssertTrue(editor.hasPendingBeginEndSelectAnchor)
        controller.beginEndSelect(item)
        XCTAssertFalse(editor.hasPendingBeginEndSelectAnchor)
    }

    func testTabSwitchResetsThePendingAnchor() throws {
        let (controller, _) = makeController()
        try setDocument("first", on: controller)
        XCTAssertTrue(run("begin-end-select", on: controller))
        XCTAssertTrue(controller.focusedEditor?.hasPendingBeginEndSelectAnchor ?? false)

        controller.addNewTab()

        XCTAssertFalse(controller.focusedEditor?.hasPendingBeginEndSelectAnchor ?? true)
    }
}
