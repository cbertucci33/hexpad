import XCTest
import AppKit
import HexpadKit
@testable import Hexpad

/// V19m status-bar field coverage. `StatusBarLineIndexTests` already pins the
/// Ln/Col index cache and the basic INS + length/lines display; this file takes
/// the other fields (selection, EOL, encoding, language) and the refresh
/// triggers (edits, caret moves, tab switches, empty buffers) as observable
/// state of the real bar. The bar renders eight fields: Ln/Col, INS/OVR,
/// selection, EOL, encoding, language, length, lines. There is no separate
/// "Pos" field and no ℙ/ℒ multi-segment or column glyph in this slice, so the
/// selection assertions below pin the plain-count behaviour that does exist.
final class StatusBarCoverageTests: XCTestCase {

    // MARK: - Fixtures

    private func makeEditor(_ text: String) -> (editor: EditorContainer, document: DocumentModel) {
        let document = DocumentModel(text: text)
        let editor = EditorContainer()
        editor.bind(to: document)
        return (editor, document)
    }

    /// Fields are laid out by horizontal origin, so a test can find one
    /// without depending on the value it currently displays.
    private func statusField(atX x: CGFloat, in bar: StatusBar) throws -> NSTextField {
        try XCTUnwrap(bar.subviews.compactMap { $0 as? NSTextField }.first { $0.frame.minX == x },
                      "status bar field at x=\(x) is missing")
    }

    private struct Fields {
        let position: String
        let mode: String
        let selection: String
        let eol: String
        let encoding: String
        let language: String
        let length: String
        let lines: String
    }

    private func fields(in bar: StatusBar) throws -> Fields {
        func value(_ x: CGFloat) throws -> String { try statusField(atX: x, in: bar).stringValue }
        return Fields(position: try value(8),
                      mode: try value(136),
                      selection: try value(178),
                      eol: try value(286),
                      encoding: try value(334),
                      language: try value(412),
                      length: try value(520),
                      lines: try value(638))
    }

    private func mouseEvent(type: NSEvent.EventType = .leftMouseDown,
                            clickCount: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(with: type,
                           location: .zero,
                           modifierFlags: [],
                           timestamp: 0,
                           windowNumber: 0,
                           context: nil,
                           eventNumber: 0,
                           clickCount: clickCount,
                           pressure: 0)!
    }

    // MARK: - 1. update(with:textView:) field population

    func testUpdatePopulatesAllEightFieldsFromDocument() throws {
        let (editor, document) = makeEditor("hello\nworld")
        document.setLanguage("Swift")
        let bar = StatusBar()

        editor.textView.setSelectedRange(NSRange(location: 8, length: 0)) // Ln 2, Col 3
        bar.update(with: document,
                   textView: editor.textView,
                   lineIndex: LineIndex("hello\nworld"))

        let shown = try fields(in: bar)
        XCTAssertEqual(shown.position, "Ln 2, Col 3")
        XCTAssertEqual(shown.mode, "INS")
        XCTAssertEqual(shown.selection, "0 selected")
        XCTAssertEqual(shown.eol, "LF")
        XCTAssertEqual(shown.encoding, "UTF-8")
        XCTAssertEqual(shown.language, "Swift")
        XCTAssertEqual(shown.length, "length : 11")
        XCTAssertEqual(shown.lines, "lines : 2")
    }

    func testLengthCountsUTF16UnitsNotCharacters() throws {
        // One astral glyph is one Character but two UTF-16 units; the bar's
        // counter must agree with the selection count (also UTF-16 based).
        let (editor, document) = makeEditor("a😀b")
        let bar = StatusBar()

        editor.textView.setSelectedRange(NSRange(location: 3, length: 1))
        bar.update(with: document, textView: editor.textView)

        let shown = try fields(in: bar)
        XCTAssertEqual(shown.length, "length : 4", "a + surrogate pair + b")
        XCTAssertEqual(shown.selection, "1 selected")
        XCTAssertEqual(shown.position, "Ln 1, Col 4", "the caret sits after the emoji")
    }

    func testStreamSelectionCountFollowsSelectedRange() throws {
        let (editor, document) = makeEditor("abcdefgh")
        let bar = StatusBar()

        editor.textView.setSelectedRange(NSRange(location: 1, length: 3))
        bar.update(with: document, textView: editor.textView)
        XCTAssertEqual(try fields(in: bar).selection, "3 selected")

        editor.textView.setSelectedRange(NSRange(location: 2, length: 0))
        bar.update(with: document, textView: editor.textView)
        XCTAssertEqual(try fields(in: bar).selection, "0 selected")
    }

    func testMultipleSelectionRangesReportPrimaryCountWithoutColumnGlyphs() throws {
        let (editor, document) = makeEditor("0123456789")
        let bar = StatusBar()

        // Discontiguous ranges are the AppKit representation of both a
        // multi-selection and a column selection. This bar has never rendered
        // the ℙ/ℒ shapes: it reports the primary range as a plain count.
        editor.textView.setSelectedRanges([NSValue(range: NSRange(location: 0, length: 2)),
                                           NSValue(range: NSRange(location: 5, length: 3))],
                                          affinity: .downstream,
                                          stillSelecting: false)
        bar.update(with: document, textView: editor.textView)

        let selection = try fields(in: bar).selection
        XCTAssertEqual(selection, "2 selected", "the primary range drives the count")
        XCTAssertFalse(selection.contains("ℙ"))
        XCTAssertFalse(selection.contains("ℒ"))
    }

    // MARK: - 2. INS/OVR toggle

    func testClickingModeFieldDrivesControllerToggleAndRefreshesDisplay() throws {
        let window = MainWindow()
        let controller = MainWindowController(window: window)
        window.contentViewController = controller
        _ = controller.view // wires status.onToggleOverwriteMode -> toggleOverwriteMode()
        let bar = try XCTUnwrap(controller.statusBar)
        let mode = try statusField(atX: 136, in: bar)
        let textView = try XCTUnwrap(controller.editorTextView as? MultiCaretTextView)
        let originalText = textView.string

        XCTAssertEqual(mode.stringValue, "INS")
        mode.mouseDown(with: mouseEvent())
        XCTAssertTrue(textView.isOverwriteMode, "the click reaches the controller")
        XCTAssertEqual(mode.stringValue, "OVR", "the controller refreshes the bar")
        XCTAssertEqual(textView.string, originalText, "toggling the mode never edits text")

        mode.mouseDown(with: mouseEvent())
        XCTAssertFalse(textView.isOverwriteMode)
        XCTAssertEqual(mode.stringValue, "INS")
    }

    func testUpdateMirrorsTextViewAsTheSingleSourceOfOverwriteTruth() throws {
        let (editor, document) = makeEditor("abc")
        let bar = StatusBar()

        bar.setOverwriteMode(true)
        XCTAssertEqual(try fields(in: bar).mode, "OVR", "the direct setter paints the field")

        // The bar deliberately keeps no second copy of the flag: the next
        // update on a real editor re-reads the text view, even in INS mode.
        bar.update(with: document, textView: editor.textView)
        XCTAssertEqual(try fields(in: bar).mode, "INS")
    }

    // MARK: - 3. Refresh triggers

    func testTextEditUpdatesLengthAndLinesCounters() throws {
        let (editor, document) = makeEditor("one\ntwo")
        let bar = StatusBar()
        bar.update(with: document, textView: editor.textView)
        XCTAssertEqual(try fields(in: bar).length, "length : 7")
        XCTAssertEqual(try fields(in: bar).lines, "lines : 2")

        document.replaceCharacters(in: NSRange(location: 7, length: 0), with: "\nthree")
        XCTAssertEqual(document.text, "one\ntwo\nthree")

        bar.update(with: document, textView: editor.textView)
        let shown = try fields(in: bar)
        XCTAssertEqual(shown.length, "length : 13", "the shared storage length is re-read")
        XCTAssertEqual(shown.lines, "lines : 3", "the cached line index was spliced")
    }

    func testCaretMoveUpdatesPositionWithoutTouchingCounters() throws {
        let (editor, document) = makeEditor("alpha\nbeta\ngamma")
        let bar = StatusBar()

        bar.update(with: document, textView: editor.textView)
        let initial = try fields(in: bar)
        XCTAssertEqual(initial.position, "Ln 1, Col 1")

        editor.textView.setSelectedRange(NSRange(location: 11, length: 0))
        bar.update(with: document, textView: editor.textView)
        let moved = try fields(in: bar)

        XCTAssertEqual(moved.position, "Ln 3, Col 1")
        XCTAssertEqual(moved.length, initial.length)
        XCTAssertEqual(moved.lines, initial.lines)
        XCTAssertEqual(moved.selection, initial.selection)
    }

    func testTabSwitchSwapsEveryFieldAndRestoresOnReturn() throws {
        let first = DocumentModel(text: "one\ntwo", encoding: "UTF-16", eolType: "CRLF")
        first.setLanguage("Swift")
        let firstEditor = EditorContainer()
        firstEditor.bind(to: first)
        firstEditor.textView.setSelectedRange(NSRange(location: 4, length: 2))

        let second = DocumentModel(text: "x\ny\nz", encoding: "UTF-8", eolType: "LF")
        second.setLanguage("Plain Text")
        let secondEditor = EditorContainer()
        secondEditor.bind(to: second)
        secondEditor.textView.setSelectedRange(NSRange(location: 0, length: 1))

        let bar = StatusBar()
        bar.update(with: first, textView: firstEditor.textView)
        let firstFields = try fields(in: bar)

        bar.update(with: second, textView: secondEditor.textView)
        let secondFields = try fields(in: bar)

        XCTAssertEqual(firstFields.position, "Ln 2, Col 1")
        XCTAssertEqual(firstFields.selection, "2 selected")
        XCTAssertEqual(firstFields.eol, "CRLF")
        XCTAssertEqual(firstFields.encoding, "UTF-16")
        XCTAssertEqual(firstFields.language, "Swift")
        XCTAssertEqual(firstFields.length, "length : 7")
        XCTAssertEqual(firstFields.lines, "lines : 2")

        XCTAssertEqual(secondFields.position, "Ln 1, Col 1")
        XCTAssertEqual(secondFields.selection, "1 selected")
        XCTAssertEqual(secondFields.eol, "LF")
        XCTAssertEqual(secondFields.encoding, "UTF-8")
        XCTAssertEqual(secondFields.language, "Plain Text")
        XCTAssertEqual(secondFields.length, "length : 5")
        XCTAssertEqual(secondFields.lines, "lines : 3")

        // Switching back must not reuse the other document's offsets/metadata.
        bar.update(with: first, textView: firstEditor.textView)
        let restored = try fields(in: bar)
        XCTAssertEqual(restored.position, firstFields.position)
        XCTAssertEqual(restored.eol, firstFields.eol)
        XCTAssertEqual(restored.encoding, firstFields.encoding)
        XCTAssertEqual(restored.language, firstFields.language)
        XCTAssertEqual(restored.length, firstFields.length)
        XCTAssertEqual(restored.lines, firstFields.lines)
    }

    func testEmptyDocumentZerosCounters() throws {
        let (editor, document) = makeEditor("")
        let bar = StatusBar()

        bar.update(with: document, textView: editor.textView)
        let shown = try fields(in: bar)

        XCTAssertEqual(shown.length, "length : 0")
        XCTAssertEqual(shown.lines, "lines : 1", "an empty buffer is one empty line")
        XCTAssertEqual(shown.selection, "0 selected")
        XCTAssertEqual(shown.position, "Ln 1, Col 1")
    }

    // MARK: - 4. EOL / encoding display

    func testEOLAndEncodingFollowCurrentDocumentValues() throws {
        let (editor, document) = makeEditor("abc")
        let bar = StatusBar()
        bar.update(with: document, textView: editor.textView)
        XCTAssertEqual(try fields(in: bar).eol, "LF")
        XCTAssertEqual(try fields(in: bar).encoding, "UTF-8")

        document.convertEOL(to: "CRLF")
        document.setEncoding("UTF-16LE")
        document.setLanguage("JSON")
        bar.update(with: document, textView: editor.textView)

        let shown = try fields(in: bar)
        XCTAssertEqual(shown.eol, "CRLF")
        XCTAssertEqual(shown.encoding, "UTF-16LE")
        XCTAssertEqual(shown.language, "JSON")

        // These fields are plain labels in this slice: a double-click has no
        // summary-dialog seam and must not rewrite what the document reports.
        let eol = try statusField(atX: 286, in: bar)
        eol.mouseDown(with: mouseEvent(clickCount: 2))
        XCTAssertEqual(eol.stringValue, "CRLF")
    }
}
