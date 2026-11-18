import XCTest
import AppKit
import HexpadKit
@testable import Hexpad

/// P17g-3: the Column Editor is app-side. The panel only collects parameters;
/// these tests drive `EditorContainer.applyColumnEditor` directly on a fixture
/// column selection (the panel seam itself is not shown or clicked), then check
/// the Search menu item's wiring, validation and controller apply path.
final class ColumnEditorDialogTests: XCTestCase {

    private var keybindingDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        // buildMainMenu resolves keybindings and macros from disk.
        keybindingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hexpad-columndialog-tests-\(UUID().uuidString)")
        KeybindingStore.overrideDirectory = keybindingDirectory
    }

    override func tearDownWithError() throws {
        KeybindingStore.overrideDirectory = nil
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

    private func makeEditor(_ text: String) -> (editor: EditorContainer, document: DocumentModel) {
        let document = DocumentModel(text: text)
        let editor = EditorContainer()
        editor.bind(to: document)
        return (editor, document)
    }

    /// A rectangle with equal columns gives one zero-length caret per row — the
    /// shipped column-selection representation from ColumnEditing.carets(in:).
    private func selectColumns(_ editor: EditorContainer, in text: String) {
        let lines = ColumnEditing.lines(in: text)
        let lastLine = max(0, lines.count - 1)
        let state = ColumnEditing.carets(
            in: text,
            rectangle: ColumnRectangle(start: TextPoint(line: 0, column: 0),
                                       end: TextPoint(line: lastLine, column: 0))
        )
        editor.setMultiCaretState(state)
    }

    private func setDocument(_ text: String, on controller: MainWindowController) throws {
        try XCTUnwrap(controller.tabStore.selectedDocument).text = text
        controller.editorTextView?.setSelectedRange(NSRange(location: 0, length: 0))
    }

    // MARK: - The panel collects parameters

    func testDialogCollectsTextAndNumberParametersHeadlessly() {
        let dialog = ColumnEditorDialog()
        XCTAssertEqual(dialog.mode, .text)
        XCTAssertNil(dialog.collectParameters(), "empty Text mode inserts nothing")

        dialog.textToInsert = "->"
        XCTAssertEqual(dialog.collectParameters(), .text("->"))

        dialog.mode = .number
        XCTAssertEqual(dialog.mode, .number)
        dialog.initialNumber = 7
        dialog.increaseBy = 3
        dialog.repeatCount = 2
        XCTAssertEqual(dialog.collectParameters(),
                       .numbers(ColumnNumberParams(initial: 7, step: 3, repeatCount: 2)))

        dialog.mode = .text
        XCTAssertEqual(dialog.textToInsert, "->", "modes keep each other's field values")
    }

    func testConfirmReportsParametersAndCancelDoesNot() {
        let dialog = ColumnEditorDialog()
        var received: [ColumnEditorParameters] = []
        dialog.onApply = { received.append($0) }

        dialog.textToInsert = "X"
        dialog.confirm(nil)
        XCTAssertEqual(received, [.text("X")])

        dialog.cancel(nil)
        XCTAssertEqual(received.count, 1, "Cancel discards what was typed")

        dialog.textToInsert = ""
        dialog.confirm(nil)
        XCTAssertEqual(received.count, 1, "OK with no text is a no-op")
    }

    // MARK: - The container applies them

    func testTextModeInsertsOnEveryColumnRowAsOneUndoStep() {
        let text = "one\ntwo\nthree"
        let (editor, document) = makeEditor(text)
        document.undoManager.removeAllActions()
        selectColumns(editor, in: text)
        XCTAssertTrue(editor.hasColumnSelection)

        XCTAssertTrue(editor.applyColumnEditor(text: "|", numbers: nil))

        XCTAssertEqual(document.text, "|one\n|two\n|three")
        XCTAssertEqual(editor.multiCaretState.carets, [
            NSRange(location: 1, length: 0),
            NSRange(location: 6, length: 0),
            NSRange(location: 11, length: 0)
        ])

        document.undoManager.undo()
        XCTAssertEqual(document.text, text, "all rows revert in one undo step")
    }

    func testNumberModeUsesOneSequenceValuePerRow() {
        let text = "a\nb\nc\nd"
        let (editor, document) = makeEditor(text)
        document.undoManager.removeAllActions()
        selectColumns(editor, in: text)

        let params = ColumnNumberParams(initial: 8, step: 1, repeatCount: 2)
        XCTAssertTrue(editor.applyColumnEditor(text: nil, numbers: params))

        // Rows 1-2 share 8, rows 3-4 share 9 (repeat = 2).
        XCTAssertEqual(document.text, "8a\n8b\n9c\n9d")
        XCTAssertEqual(editor.multiCaretState.carets, [
            NSRange(location: 1, length: 0),
            NSRange(location: 4, length: 0),
            NSRange(location: 7, length: 0),
            NSRange(location: 10, length: 0)
        ], "each earlier row's insertion shifts the carets below it")

        document.undoManager.undo()
        XCTAssertEqual(document.text, text)
    }

    func testRectangularColumnSelectionIsReplacedAtEveryRow() {
        let text = "abcdef\nghijkl"
        let (editor, document) = makeEditor(text)
        let state = ColumnEditing.carets(
            in: text,
            rectangle: ColumnRectangle(start: TextPoint(line: 0, column: 1),
                                       end: TextPoint(line: 1, column: 3))
        )
        editor.setMultiCaretState(state)

        XCTAssertTrue(editor.applyColumnEditor(text: "XX", numbers: nil))
        XCTAssertEqual(document.text, "aXXdef\ngXXjkl")
        XCTAssertEqual(editor.multiCaretState.carets, [
            NSRange(location: 3, length: 0),
            NSRange(location: 10, length: 0)
        ])
    }

    func testApplyWithoutValuesIsANoOp() {
        let text = "one\ntwo"
        let (editor, document) = makeEditor(text)
        selectColumns(editor, in: text)
        document.undoManager.removeAllActions()

        XCTAssertFalse(editor.applyColumnEditor(text: nil, numbers: nil))
        XCTAssertFalse(editor.applyColumnEditor(text: "", numbers: nil))
        XCTAssertEqual(document.text, text)
        XCTAssertFalse(document.undoManager.canUndo)
    }

    // MARK: - Menu wiring, validation and controller apply path

    func testSearchMenuHasColumnEditorNextToTheColumnModeItem() throws {
        let menu = HexpadAppDelegate().buildMainMenu()
        let searchMenu = try XCTUnwrap(menu.item(withTitle: "Search")?.submenu)
        let titles = searchMenu.items.map(\.title)

        let columnModeIndex = try XCTUnwrap(titles.firstIndex(of: "Begin/End Select in Column Mode"))
        let editorIndex = try XCTUnwrap(titles.firstIndex(of: "Column Editor…"))
        XCTAssertEqual(editorIndex, columnModeIndex + 2, "one separator between the column items")

        let item = searchMenu.items[editorIndex]
        XCTAssertEqual(item.action, #selector(MainWindowController.showColumnEditor(_:)))
        XCTAssertNil(item.target, "the focused controller owns the action and validation")
        XCTAssertEqual(item.keyEquivalent, "", "no invented chord (N++ Alt+C has no Mac default)")
    }

    func testValidationRequiresAColumnSelection() throws {
        let (controller, _) = makeController()
        let item = NSMenuItem(title: "Column Editor…",
                              action: #selector(MainWindowController.showColumnEditor(_:)),
                              keyEquivalent: "")
        let text = "one\ntwo\nthree"
        try setDocument(text, on: controller)
        let editor = try XCTUnwrap(controller.focusedEditor)
        editor.textView.setSelectedRange(NSRange(location: 0, length: 0))

        XCTAssertFalse(editor.hasColumnSelection)
        XCTAssertFalse(controller.canShowColumnEditor())
        XCTAssertFalse(controller.validateMenuItem(item), "no column selection -> disabled")

        selectColumns(editor, in: text)
        XCTAssertTrue(controller.validateMenuItem(item))
        XCTAssertNotNil(controller.columnEditorDialog().onApply)

        editor.collapseMultiCaret()
        XCTAssertFalse(controller.validateMenuItem(item))
    }

    func testControllerAppliesTheDialogParametersToTheFocusedEditor() throws {
        let (controller, _) = makeController()
        let text = "one\ntwo\nthree"
        try setDocument(text, on: controller)
        let editor = try XCTUnwrap(controller.focusedEditor)
        let document = try XCTUnwrap(controller.tabStore.selectedDocument)
        document.undoManager.removeAllActions()
        selectColumns(editor, in: text)

        let dialog = controller.columnEditorDialog()
        XCTAssertTrue(dialog === controller.columnEditorDialog(), "the panel is reused")
        dialog.textToInsert = "@"
        let parameters = try XCTUnwrap(dialog.collectParameters())

        // OK's path: the controller-owned closure applies to the focused editor.
        dialog.onApply?(parameters)

        XCTAssertEqual(document.text, "@one\n@two\n@three")
        document.undoManager.undo()
        XCTAssertEqual(document.text, text)
    }
}
