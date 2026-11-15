import XCTest
import AppKit
import HexpadKit
@testable import Hexpad

/// Wiring tests for the status bar's `LineIndex` fast path. `update` has two
/// ways to compute Ln/Col: the per-bar cached index (the normal app path) and
/// an index the caller already owns. These tests exercise the real `StatusBar`
/// against the real editor text view and assert the visible position label, so
/// they pin the API contract rather than the private cache.
final class StatusBarLineIndexTests: XCTestCase {

    // MARK: - Fixtures

    private func makeEditor(_ text: String) -> (editor: EditorContainer, document: DocumentModel) {
        let document = DocumentModel(text: text)
        let editor = EditorContainer()
        editor.bind(to: document)
        return (editor, document)
    }

    /// The position label is the leftmost text field in the bar. Locating it by
    /// its laid-out frame keeps the test independent of the text it displays,
    /// which changes with every caret move.
    private func positionLabel(in bar: StatusBar) throws -> NSTextField {
        try XCTUnwrap(bar.subviews.compactMap { $0 as? NSTextField }.first { $0.frame.minX == 8 },
                      "status bar position label is missing")
    }

    /// Runs one status-bar update and returns what the user would see.
    @discardableResult
    private func show(_ bar: StatusBar,
                      document: DocumentModel?,
                      textView: NSTextView,
                      lineIndex: LineIndex? = nil) throws -> String {
        bar.update(with: document, textView: textView, lineIndex: lineIndex)
        return try positionLabel(in: bar).stringValue
    }

    /// The full-scan oracle `LineIndex` is required to reproduce exactly.
    private func referencePosition(_ text: String, caret: Int) -> String {
        let line = GutterGeometry.logicalLine(of: caret, in: text)
        let first = GutterGeometry.firstCharIndex(of: line, in: text)
        return "Ln \(line), Col \(caret - first + 1)"
    }

    // MARK: - Supplied index equals the cached path

    func testExplicitIndexMatchesCachedPathForEveryTextShape() throws {
        let crlfConverted = EOLDetective.converting("one\r\ntwo\r\nline three\r\n",
                                                    to: EOLDetective.lf)
        let cases: [(name: String, text: String, carets: [Int])] = [
            ("empty text", "", [0]),
            ("single line", "hello", [0, 2, 5]),
            ("trailing newline", "one\ntwo\n", [0, 3, 4, 7, 8]),
            ("CRLF converted to LF", crlfConverted, [0, 3, 4, 7, 8, 18, 19]),
            ("emoji and unicode", "a😀b\ncafé\n𝄞x", [0, 1, 3, 4, 5, 9, 10, 13]),
            ("line boundaries", "alpha\nbeta\ngamma", [0, 5, 6, 10, 11, 16])
        ]

        for testCase in cases {
            let (editor, document) = makeEditor(testCase.text)
            XCTAssertNotNil(editor.textView.textStorage,
                            "\(testCase.name): the editor needs a real text storage")
            let bar = StatusBar()
            let length = (testCase.text as NSString).length
            let index = LineIndex(testCase.text)

            for caret in testCase.carets {
                let location = min(caret, length)
                editor.textView.setSelectedRange(NSRange(location: location, length: 0))

                let cached = try show(bar, document: document, textView: editor.textView)
                let supplied = try show(bar,
                                        document: document,
                                        textView: editor.textView,
                                        lineIndex: index)

                XCTAssertEqual(cached, supplied,
                               "\(testCase.name) at \(location): the two paths disagree")
                XCTAssertEqual(cached, referencePosition(testCase.text, caret: location),
                               "\(testCase.name) at \(location)")
            }
        }
    }

    // MARK: - Cache invalidation

    func testCacheInvalidatesWhenAnEditGrowsTheText() throws {
        let (editor, document) = makeEditor("one\ntwo")
        let bar = StatusBar()

        editor.textView.setSelectedRange(NSRange(location: 4, length: 0))
        let before = try show(bar, document: document, textView: editor.textView)
        XCTAssertEqual(before, "Ln 2, Col 1")

        // Insert a whole line ahead of the caret. The cached index's offsets
        // no longer describe the buffer.
        document.replaceCharacters(in: NSRange(location: 0, length: 0), with: "zero\n")
        XCTAssertEqual(editor.textView.string, "zero\none\ntwo")

        editor.textView.setSelectedRange(NSRange(location: 9, length: 0))
        let shifted = try show(bar, document: document, textView: editor.textView)
        XCTAssertEqual(shifted, "Ln 3, Col 1")

        editor.textView.setSelectedRange(NSRange(location: 12, length: 0))
        let end = try show(bar, document: document, textView: editor.textView)
        XCTAssertEqual(end, "Ln 3, Col 4")
    }

    func testCacheInvalidatesOnSameLengthEditThatMovesALineBoundary() throws {
        let (editor, document) = makeEditor("abcd")
        let bar = StatusBar()

        editor.textView.setSelectedRange(NSRange(location: 3, length: 0))
        let before = try show(bar, document: document, textView: editor.textView)
        XCTAssertEqual(before, "Ln 1, Col 4")

        // Same UTF-16 length (4), but replacing "c" with an LF moves the line
        // boundary one slot left. The length guard cannot catch this; the edit
        // generation is what forces the index to rebuild.
        document.replaceCharacters(in: NSRange(location: 2, length: 1), with: "\n")
        XCTAssertEqual(editor.textView.string, "ab\nd")

        editor.textView.setSelectedRange(NSRange(location: 2, length: 0))
        let beforeNewline = try show(bar, document: document, textView: editor.textView)
        XCTAssertEqual(beforeNewline, "Ln 1, Col 3")

        editor.textView.setSelectedRange(NSRange(location: 3, length: 0))
        let afterNewline = try show(bar, document: document, textView: editor.textView)
        XCTAssertEqual(afterNewline, "Ln 2, Col 1",
                       "a stale index would still report Ln 1, Col 4")

        editor.textView.setSelectedRange(NSRange(location: 4, length: 0))
        let end = try show(bar, document: document, textView: editor.textView)
        XCTAssertEqual(end, "Ln 2, Col 2")
    }

    // MARK: - Caret moves reuse the cached index

    func testCaretMovesOnUnchangedTextKeepTheCachedIndexContract() throws {
        let text = "alpha\nbeta\ngamma\ndelta"
        let (editor, document) = makeEditor(text)
        let bar = StatusBar()
        let index = LineIndex(text)
        let moves: [(caret: Int, position: String)] = [
            (0, "Ln 1, Col 1"),
            (5, "Ln 1, Col 6"),
            (6, "Ln 2, Col 1"),
            (10, "Ln 2, Col 5"),
            (11, "Ln 3, Col 1"),
            (16, "Ln 3, Col 6"),
            (17, "Ln 4, Col 1"),
            (22, "Ln 4, Col 6")
        ]
        let originalText = editor.textView.string

        for move in moves {
            editor.textView.setSelectedRange(NSRange(location: move.caret, length: 0))

            let cached = try show(bar, document: document, textView: editor.textView)
            XCTAssertEqual(cached, move.position)

            // The caller-supplied path is the observable contract for reuse:
            // after any number of caret-only moves it must still agree with the
            // cached path, which is the one the app actually runs.
            let supplied = try show(bar,
                                    document: document,
                                    textView: editor.textView,
                                    lineIndex: index)
            XCTAssertEqual(supplied, cached, "caret move at \(move.caret)")
            XCTAssertEqual(cached, referencePosition(text, caret: move.caret))
        }

        XCTAssertEqual(editor.textView.string, originalText,
                       "caret moves must not touch the text")
    }
}
