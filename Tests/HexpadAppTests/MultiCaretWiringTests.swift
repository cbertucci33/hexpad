import XCTest
import AppKit
import HexpadKit
@testable import Hexpad

/// State-driving tests for the app-side multi-caret wiring. They exercise the
/// real editor container and its `NSTextView` subclass rather than duplicating
/// the gesture logic, but assert model state instead of pixels.
final class MultiCaretWiringTests: XCTestCase {

    private func makeEditor(_ text: String) -> (editor: EditorContainer, document: DocumentModel) {
        let document = DocumentModel(text: text)
        let editor = EditorContainer()
        editor.bind(to: document)
        return (editor, document)
    }

    // MARK: - Placing and collapsing carets

    func testAdditionalCaretIsStoredInDocumentOrder() {
        let (editor, _) = makeEditor("one\ntwo\nthree")
        editor.textView.setSelectedRange(NSRange(location: 4, length: 0))

        editor.placeAdditionalCaret(atCharacterIndex: 0)

        XCTAssertEqual(editor.multiCaretState.carets,
                       [NSRange(location: 0, length: 0),
                        NSRange(location: 4, length: 0)])
        XCTAssertEqual(editor.textView.selectedRange, NSRange(location: 0, length: 0),
                       "the text view mirrors the primary (first) caret")
    }

    func testClickingPrimaryPositionAgainCollapsesToSingleCaret() {
        let (editor, _) = makeEditor("one\ntwo\nthree")
        editor.textView.setSelectedRange(NSRange(location: 0, length: 0))
        editor.placeAdditionalCaret(atCharacterIndex: 4)
        XCTAssertEqual(editor.multiCaretState.count, 2)

        editor.placeAdditionalCaret(atCharacterIndex: 0)

        XCTAssertEqual(editor.multiCaretState.carets, [NSRange(location: 0, length: 0)])
    }

    func testClickingAnExistingExtraCaretTogglesItOff() {
        let (editor, _) = makeEditor("one\ntwo\nthree")
        editor.textView.setSelectedRange(NSRange(location: 0, length: 0))
        editor.placeAdditionalCaret(atCharacterIndex: 4)
        editor.placeAdditionalCaret(atCharacterIndex: 8)
        XCTAssertEqual(editor.multiCaretState.count, 3)

        editor.placeAdditionalCaret(atCharacterIndex: 4)

        XCTAssertEqual(editor.multiCaretState.carets,
                       [NSRange(location: 0, length: 0),
                        NSRange(location: 8, length: 0)])
    }

    func testEscapeCollapsesExtraCarets() {
        let (editor, _) = makeEditor("one\ntwo")
        editor.textView.setSelectedRange(NSRange(location: 0, length: 0))
        editor.placeAdditionalCaret(atCharacterIndex: 4)
        XCTAssertEqual(editor.multiCaretState.count, 2)

        editor.textView.cancelOperation(nil)

        XCTAssertEqual(editor.multiCaretState.carets, [NSRange(location: 0, length: 0)])
    }

    // MARK: - Editing through MultiCaretApplier

    func testTypingAppliesAtEveryCaretAsOneUndoStep() {
        let (editor, document) = makeEditor("ab")
        document.undoManager.removeAllActions()
        editor.textView.setSelectedRange(NSRange(location: 0, length: 0))
        editor.placeAdditionalCaret(atCharacterIndex: 1)

        editor.textView.insertText("X", replacementRange: editor.textView.selectedRange)

        XCTAssertEqual(document.text, "XaXb")
        XCTAssertEqual(editor.multiCaretState.carets,
                       [NSRange(location: 1, length: 0),
                        NSRange(location: 3, length: 0)])

        document.undoManager.undo()
        XCTAssertEqual(document.text, "ab", "the whole action must undo in one step")
    }

    func testBackspaceDeletesAtEveryCaretAsOneUndoStep() {
        let (editor, document) = makeEditor("abc\ndef")
        document.undoManager.removeAllActions()
        editor.textView.setSelectedRange(NSRange(location: 3, length: 0))
        editor.placeAdditionalCaret(atCharacterIndex: 7)
        XCTAssertEqual(editor.multiCaretState.carets,
                       [NSRange(location: 3, length: 0),
                        NSRange(location: 7, length: 0)])

        editor.textView.deleteBackward(nil)

        XCTAssertEqual(document.text, "ab\nde")
        XCTAssertEqual(editor.multiCaretState.carets,
                       [NSRange(location: 2, length: 0),
                        NSRange(location: 5, length: 0)])

        document.undoManager.undo()
        XCTAssertEqual(document.text, "abc\ndef")
    }

    func testPasteAppliesAtEveryCaretAsOneUndoStep() {
        let (editor, document) = makeEditor("ab\ncd")
        document.undoManager.removeAllActions()
        editor.textView.setSelectedRange(NSRange(location: 1, length: 0))
        editor.placeAdditionalCaret(atCharacterIndex: 4)

        let pasteboard = NSPasteboard.general
        let saved = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        pasteboard.setString("Z", forType: .string)
        defer {
            pasteboard.clearContents()
            if let saved {
                pasteboard.setString(saved, forType: .string)
            }
        }

        editor.textView.paste(nil)

        XCTAssertEqual(document.text, "aZb\ncZd")
        document.undoManager.undo()
        XCTAssertEqual(document.text, "ab\ncd")
    }

    // MARK: - Column selection

    func testOptionDragRectangleBecomesMultiCaretStateAndEdits() {
        let text = "abc\ndef\nghi"
        let (editor, document) = makeEditor(text)
        document.undoManager.removeAllActions()

        editor.textView.setSelectedRange(NSRange(location: 1, length: 0))
        editor.beginColumnSelection(atCharacterIndex: 1)
        editor.updateColumnSelection(toCharacterIndex: 6)
        editor.endColumnSelection()

        let expected = ColumnEditing.carets(
            in: text,
            rectangle: ColumnRectangle(start: TextPoint(line: 0, column: 1),
                                       end: TextPoint(line: 1, column: 2))
        )
        XCTAssertEqual(editor.multiCaretState, expected)
        XCTAssertEqual(editor.multiCaretState.carets,
                       [NSRange(location: 1, length: 1),
                        NSRange(location: 5, length: 1)])

        editor.applyMultiCaretInsertion("X")

        XCTAssertEqual(document.text, "aXc\ndXf\nghi")
        document.undoManager.undo()
        XCTAssertEqual(document.text, text)
    }

    // MARK: - Selection notification arbitration

    func testOrdinarySelectionChangeCollapsesExtraCarets() {
        let (editor, _) = makeEditor("one\ntwo\nthree")
        editor.textView.setSelectedRange(NSRange(location: 0, length: 0))
        editor.placeAdditionalCaret(atCharacterIndex: 4)
        XCTAssertEqual(editor.multiCaretState.count, 2)

        editor.textView.setSelectedRange(NSRange(location: 2, length: 0))

        XCTAssertEqual(editor.multiCaretState.carets, [NSRange(location: 2, length: 0)])
    }

    func testSelectionNotificationEchoingPrimaryKeepsExtraCarets() {
        let (editor, _) = makeEditor("one\ntwo\nthree")
        editor.textView.setSelectedRange(NSRange(location: 0, length: 0))
        editor.placeAdditionalCaret(atCharacterIndex: 4)
        XCTAssertEqual(editor.multiCaretState.count, 2)

        // Simulate a late notification that only reports the primary caret.
        NotificationCenter.default.post(
            name: NSNotification.Name("NSTextViewDidChangeSelectionNotification"),
            object: editor.textView
        )

        XCTAssertEqual(editor.multiCaretState.count, 2,
                       "an echo of the primary selection must not fight the caret state")
    }

    // MARK: - Minimal commit diff

    func testTextChangeIsTheSmallestReplacement() {
        let change = MultiCaretEditing.change(from: "abc", to: "aXc")
        XCTAssertEqual(change, MultiCaretEditing.TextChange(range: NSRange(location: 1, length: 1),
                                                            replacement: "X"))
    }

    func testTextChangeHandlesInsertionAtEndAndEmptyDocuments() {
        XCTAssertEqual(MultiCaretEditing.change(from: "ab", to: "abZ"),
                       MultiCaretEditing.TextChange(range: NSRange(location: 2, length: 0),
                                                    replacement: "Z"))
        XCTAssertEqual(MultiCaretEditing.change(from: "", to: "Z"),
                       MultiCaretEditing.TextChange(range: NSRange(location: 0, length: 0),
                                                    replacement: "Z"))
        XCTAssertNil(MultiCaretEditing.change(from: "same", to: "same"))
    }
}
