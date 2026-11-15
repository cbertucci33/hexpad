import XCTest
import AppKit
import HexpadKit
@testable import Hexpad

/// Tests for the document minimap: the cached line-colour model, the viewport
/// overlay geometry, the click-to-scroll mapping, and the editor-container
/// integration that reserves the fixed trailing column.
final class MinimapTests: XCTestCase {

    private func tenLineText() -> String {
        (1...10).map(String.init).joined(separator: "\n")
    }

    // MARK: - Line-colour model

    func testModelHasOneRowPerLogicalLineIncludingTrailingEmptyLine() {
        let text = "let a = 1\n\n// note\nlet b = 2\n"
        let model = MinimapLineModel.compute(text: text, language: .swift)

        XCTAssertEqual(model.lines.count, GutterGeometry.lineCount(in: text))
        XCTAssertEqual(model.lines.map(\.line), [1, 2, 3, 4, 5])
        XCTAssertNil(model.lines[1].type, "a blank line has no dominant token type")
        XCTAssertNil(model.lines[4].type, "the final empty line is blank")
    }

    func testBlankLineHasNoWidthAndCommentLineIsCommentColoured() {
        let text = "// a comment with more than spaces\n\n"
        let model = MinimapLineModel.compute(text: text, language: .swift)

        XCTAssertEqual(model.lines[0].type, .comment)
        XCTAssertGreaterThan(model.lines[0].widthFraction, 0)
        XCTAssertNil(model.lines[1].type)
        XCTAssertEqual(model.lines[1].widthFraction, 0)
    }

    func testDominantTypePicksTheLargestCoverageAndIgnoresWhitespace() {
        let stringHeavy: [TokenType: Int] = [.comment: 3, .string: 7, .whitespace: 100]
        XCTAssertEqual(MinimapLineModel.dominantType(in: stringHeavy), .string)
        XCTAssertNil(MinimapLineModel.dominantType(in: [.whitespace: 100]),
                     "whitespace can never dominate a row")
    }

    func testDominantTypeTiesUseDeclarationOrder() {
        XCTAssertEqual(MinimapLineModel.dominantType(in: [.variable: 4, .keyword: 4]),
                       .keyword)
        XCTAssertEqual(MinimapLineModel.dominantType(in: [.plain: 2, .number: 2]),
                       .number)
    }

    func testLineWidthIsProportionalAndLongLinesFillTheMinimap() {
        let text = String(repeating: "a", count: 50) + "\n"
            + String(repeating: "b", count: 250)
        let model = MinimapLineModel.compute(text: text, language: .plain)

        XCTAssertEqual(model.lines[0].widthFraction, 0.5, accuracy: 0.001)
        XCTAssertEqual(model.lines[1].widthFraction, 1.0,
                       "lines longer than the reference width are clamped, not scaled")
        XCTAssertEqual(model.lines[0].type, .plain)
    }

    func testModelEqualityIsValueBasedSoUnchangedRowsSkipRepaint() {
        let text = "let a = 1\nlet b = 2"
        let first = MinimapLineModel.compute(text: text, language: .swift)
        let second = MinimapLineModel.compute(text: text, language: .swift)

        XCTAssertEqual(first, second)
        XCTAssertNotEqual(first,
                          MinimapLineModel.compute(text: text, language: .plain),
                          "a language change must invalidate the cached model")
    }

    // MARK: - Viewport overlay

    func testViewportOverlayCoversVisibleLogicalLines() {
        let text = tenLineText()
        // Lines 3-4 are visible: chars 4..<8 in "1\n2\n3\n4\n...".
        let rect = MinimapGeometry.viewportRect(
            visibleCharacterRange: NSRange(location: 4, length: 4),
            text: text,
            lineCount: 10,
            width: 100,
            height: 100
        )

        XCTAssertNotNil(rect)
        XCTAssertEqual(rect?.minY ?? -1, 20, accuracy: 0.001)
        XCTAssertEqual(rect?.height ?? -1, 20, accuracy: 0.001)
        XCTAssertEqual(rect?.width ?? -1, 100, accuracy: 0.001)
    }

    func testViewportOverlayNearEndOfDocumentStaysInsideBounds() {
        let text = tenLineText()
        let rect = MinimapGeometry.viewportRect(
            visibleCharacterRange: NSRange(location: 16, length: 4),
            text: text,
            lineCount: 10,
            width: 100,
            height: 100
        )

        XCTAssertNotNil(rect)
        XCTAssertEqual(rect?.minY ?? -1, 80, accuracy: 0.001)
        XCTAssertLessThanOrEqual(rect?.maxY ?? .infinity, 100)
    }

    func testTinyVisibleBandKeepsAMinimumOverlayHeight() {
        let text = (1...1_000).map(String.init).joined(separator: "\n")
        let rect = MinimapGeometry.viewportRect(
            visibleCharacterRange: NSRange(location: 0, length: 1),
            text: text,
            lineCount: 1_000,
            width: 100,
            height: 100
        )

        XCTAssertNotNil(rect)
        XCTAssertEqual(rect?.height ?? 0,
                       MinimapGeometry.minimumViewportHeight,
                       accuracy: 0.001)
    }

    // MARK: - Click / drag mapping

    func testMinimapYResolvesToTheClickedLogicalLine() {
        XCTAssertEqual(MinimapGeometry.lineIndex(atY: 0, lineCount: 10, height: 100), 0)
        XCTAssertEqual(MinimapGeometry.lineIndex(atY: 50, lineCount: 10, height: 100), 5)
        XCTAssertEqual(MinimapGeometry.lineIndex(atY: 100, lineCount: 10, height: 100), 9,
                       "a click at the bottom edge clamps to the last line")
        XCTAssertEqual(MinimapGeometry.lineIndex(atY: -20, lineCount: 10, height: 100), 0)
    }

    func testMinimapClickMapsToTheFirstCharacterOfThatLine() {
        let text = tenLineText()
        let index = MinimapGeometry.characterIndex(atY: 50,
                                                  text: text,
                                                  lineCount: 10,
                                                  height: 100)
        XCTAssertEqual(index, GutterGeometry.firstCharIndex(of: 6, in: text),
                       "Y=50 is line 6, whose first character is index 10")
        XCTAssertEqual(index, 10)
    }

    func testScrollOriginCentresTheClickedPositionAndClamps() {
        XCTAssertEqual(MinimapGeometry.scrollOriginY(fraction: 0.5,
                                                     documentHeight: 2_000,
                                                     viewportHeight: 400),
                       800, accuracy: 0.001)
        XCTAssertEqual(MinimapGeometry.scrollOriginY(fraction: 0,
                                                     documentHeight: 2_000,
                                                     viewportHeight: 400),
                       0, accuracy: 0.001)
        XCTAssertEqual(MinimapGeometry.scrollOriginY(fraction: 1,
                                                     documentHeight: 2_000,
                                                     viewportHeight: 400),
                       1_600, accuracy: 0.001,
                       "the last click cannot scroll past the end of the document")
    }

    // MARK: - Editor integration

    func testEditorReservesFixedWidthForBoundDocumentOnly() {
        let editor = EditorContainer()
        editor.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        editor.layout()

        XCTAssertTrue(editor.minimap.isHidden, "no document is bound yet")
        XCTAssertEqual(editor.scrollView.frame.width,
                       900 - LineNumberGutter.width, accuracy: 0.5)

        let document = DocumentModel(text: "let a = 1\nlet b = 2")
        editor.bind(to: document)
        editor.layout()

        XCTAssertFalse(editor.minimap.isHidden)
        XCTAssertEqual(editor.minimap.frame.width, MinimapView.width, accuracy: 0.5)
        XCTAssertEqual(editor.minimap.frame.maxX, 900, accuracy: 0.5)
        XCTAssertEqual(editor.scrollView.frame.maxX,
                       editor.minimap.frame.minX, accuracy: 0.5,
                       "the minimap never overlaps the editor scroller")

        editor.bind(to: nil)
        editor.layout()

        XCTAssertTrue(editor.minimap.isHidden)
        XCTAssertEqual(editor.scrollView.frame.width,
                       900 - LineNumberGutter.width, accuracy: 0.5,
                       "the reserved width returns to the editor when unbound")
    }

    func testTextChangeInvalidatesAndRebuildsTheCachedModel() {
        let document = DocumentModel(text: "let a = 1\nlet b = 2")
        document.setLanguage(Language.swift.rawValue)
        let editor = EditorContainer()
        editor.bind(to: document)

        XCTAssertEqual(editor.minimap.lineModel?.lines.count, 2)
        XCTAssertFalse(editor.minimap.modelNeedsRebuild)

        document.replaceCharacters(in: NSRange(location: 0, length: 0), with: "\n")

        XCTAssertTrue(editor.minimap.modelNeedsRebuild,
                      "the storage notification marks the cached model dirty")
        editor.minimap.rebuildModelNow()
        XCTAssertFalse(editor.minimap.modelNeedsRebuild)
        XCTAssertEqual(editor.minimap.lineModel?.lines.count, 3)
    }

    func testSingleLineEditRecomputesOnlyThatRow() throws {
        let text = "let a = 1\nlet b = 2\nlet c = 3\nlet d = 4\nlet e = 5"
        let document = DocumentModel(text: text)
        document.setLanguage(Language.swift.rawValue)
        let editor = EditorContainer()
        editor.bind(to: document)

        let before = try XCTUnwrap(editor.minimap.lineModel)
        // Grow the number literal on the third line: its width changes, while
        // rows outside the edited band (plus one line of context) are untouched.
        document.replaceCharacters(in: NSRange(location: 28, length: 1),
                                   with: "3333")
        editor.minimap.rebuildModelNow()

        let after = try XCTUnwrap(editor.minimap.lineModel)
        XCTAssertEqual(after.lines.count, before.lines.count)
        XCTAssertEqual(after.lines[0], before.lines[0])
        XCTAssertNotEqual(after.lines[2], before.lines[2],
                          "the edited row was recomputed")
        XCTAssertEqual(after.lines[3], before.lines[3])
        XCTAssertEqual(after.lines[4], before.lines[4],
                       "rows outside the edited band keep their cached model")
        XCTAssertEqual(after.lineRanges[0], before.lineRanges[0])
        XCTAssertEqual(after.lineRanges[4].length, before.lineRanges[4].length,
                       "only the character offsets of later rows shift with the edit")
        XCTAssertEqual(after.lineRanges[4].location, before.lineRanges[4].location + 3)
    }

    func testInsertingALineRenumbersPreservedRowsFromTheCache() throws {
        let document = DocumentModel(text: "let a = 1\nlet b = 2\nlet c = 3")
        document.setLanguage(Language.swift.rawValue)
        let editor = EditorContainer()
        editor.bind(to: document)

        let before = try XCTUnwrap(editor.minimap.lineModel)
        // Split the second line with a newline: line 3 keeps its content but
        // moves down one row.
        document.replaceCharacters(in: NSRange(location: 18, length: 0), with: "\n")
        editor.minimap.rebuildModelNow()

        let after = try XCTUnwrap(editor.minimap.lineModel)
        XCTAssertEqual(after.lines.count, before.lines.count + 1)
        XCTAssertEqual(after.lines[after.lines.count - 1].line,
                       before.lines[before.lines.count - 1].line + 1)
        XCTAssertEqual(after.lines[after.lines.count - 1].type,
                       before.lines[before.lines.count - 1].type,
                       "the trailing row was shifted, not re-tokenized away")
    }

    func testRebindUsesTheNewlySelectedLanguage() {
        let document = DocumentModel(text: "// note")
        document.setLanguage(Language.plain.rawValue)
        let editor = EditorContainer()
        editor.bind(to: document)

        XCTAssertEqual(editor.minimap.lineModel?.lines.first?.type, .plain)

        document.setLanguage(Language.swift.rawValue)
        editor.bind(to: document)

        XCTAssertEqual(editor.minimap.lineModel?.lines.first?.type, .comment,
                       "rebinding after a language change re-tokenizes the minimap")
    }
}
