import XCTest
import AppKit
import HexpadKit
@testable import Hexpad

/// Lifecycle coverage for the live brace highlight: it appears on both
/// brackets when the caret (or a one-character selection) touches one, moves
/// with the caret, clears when the caret leaves, and switches to the "bad
/// brace" tone for an unmatched bracket. Assertions read the overlay's state
/// and its temporary-attribute marks, never pixels.
final class BraceHighlightTests: XCTestCase {

    private func makeEditor(_ text: String) -> (editor: EditorContainer, document: DocumentModel) {
        let document = DocumentModel(text: text)
        document.setLanguage(Language.swift.rawValue)
        let editor = EditorContainer()
        editor.bind(to: document)
        return (editor, document)
    }

    private func mark(_ editor: EditorContainer, at index: Int) -> Any? {
        editor.textView.layoutManager?.temporaryAttribute(
            BraceHighlight.attributeKey,
            atCharacterIndex: index,
            effectiveRange: nil
        )
    }

    func testCaretAdjacentToBracketHighlightsBothBrackets() {
        let (editor, document) = makeEditor("{ body }") // 0 '{' ... 7 '}'
        defer { _ = document }

        editor.textView.setSelectedRange(NSRange(location: 1, length: 0))

        XCTAssertEqual(editor.braceHighlight.highlight?.ranges,
                       [NSRange(location: 0, length: 1),
                        NSRange(location: 7, length: 1)])
        XCTAssertEqual(editor.braceHighlight.highlight?.style, .match)
        XCTAssertNotNil(mark(editor, at: 0), "opening bracket is marked")
        XCTAssertNotNil(mark(editor, at: 7), "closing bracket is marked")
    }

    func testMovingCaretAwayClearsTheHighlight() {
        let (editor, document) = makeEditor("{ body }")
        defer { _ = document }

        editor.textView.setSelectedRange(NSRange(location: 1, length: 0))
        XCTAssertNotNil(editor.braceHighlight.highlight)

        editor.textView.setSelectedRange(NSRange(location: 3, length: 0))

        XCTAssertNil(editor.braceHighlight.highlight)
        XCTAssertNil(mark(editor, at: 0), "old opening mark is removed")
        XCTAssertNil(mark(editor, at: 7), "old closing mark is removed")
    }

    func testUnmatchedBracketUsesBadBraceStyle() {
        let (editor, document) = makeEditor("{ abc")
        defer { _ = document }

        editor.textView.setSelectedRange(NSRange(location: 1, length: 0))

        XCTAssertEqual(editor.braceHighlight.highlight?.ranges,
                       [NSRange(location: 0, length: 1)])
        XCTAssertEqual(editor.braceHighlight.highlight?.style, .unmatched)
        XCTAssertNotNil(mark(editor, at: 0))
    }

    func testOneCharacterBracketSelectionCountsAsAdjacent() {
        let (editor, document) = makeEditor("{ body }")
        defer { _ = document }

        editor.textView.setSelectedRange(NSRange(location: 0, length: 1))

        XCTAssertEqual(editor.braceHighlight.highlight?.ranges,
                       [NSRange(location: 0, length: 1),
                        NSRange(location: 7, length: 1)])
        XCTAssertEqual(editor.braceHighlight.highlight?.style, .match)
    }
}
