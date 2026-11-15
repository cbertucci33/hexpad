import XCTest
@testable import HexpadKit

final class CommandRegistryTests: XCTestCase {

    // MARK: - Helpers

    @discardableResult
    private func assertCommand(_ identifier: String,
                               text: String,
                               selection: NSRange,
                               expectedText: String,
                               expectedSelection: NSRange,
                               file: StaticString = #filePath,
                               line: UInt = #line) -> (text: String, selection: NSRange)? {
        guard let result = CommandRegistry.default.execute(identifier, text: text, selection: selection) else {
            XCTFail("Missing command: \(identifier)", file: file, line: line)
            return nil
        }
        XCTAssertEqual(result.text, expectedText, "text for \(identifier)", file: file, line: line)
        XCTAssertEqual(result.selection, expectedSelection, "selection for \(identifier)", file: file, line: line)
        return result
    }

    // MARK: - Registry

    func testDefaultCommandIdentifiersAndOrder() {
        XCTAssertEqual(CommandRegistry.default.commands.map(\.identifier), [
            "duplicate-line",
            "delete-line",
            "move-line-up",
            "move-line-down",
            "toggle-line-comment",
            "uppercase",
            "lowercase"
        ])
    }

    func testDefaultCommandTitles() {
        XCTAssertEqual(CommandRegistry.default.commands.map(\.title), [
            "Duplicate Line",
            "Delete Line",
            "Move Line Up",
            "Move Line Down",
            "Toggle Line Comment",
            "Uppercase",
            "Lowercase"
        ])
    }

    func testLookupByIdentifier() {
        XCTAssertEqual(CommandRegistry.default.command(for: "uppercase")?.title, "Uppercase")
        XCTAssertEqual(CommandRegistry.default.command(for: "toggle-line-comment")?.title, "Toggle Line Comment")
        XCTAssertNil(CommandRegistry.default.command(for: "not-a-command"))
    }

    func testExecuteUnknownIdentifierReturnsNil() {
        XCTAssertNil(CommandRegistry.default.execute("not-a-command", text: "abc", selection: NSRange(location: 0, length: 0)))
    }

    func testCustomCommentPrefix() {
        let registry = CommandRegistry(lineCommentPrefix: "# ")
        let result = registry.execute("toggle-line-comment", text: "  abc", selection: NSRange(location: 2, length: 0))
        XCTAssertEqual(result?.text, "  # abc")
    }

    func testRegistryWithExplicitCommands() {
        let command = EditorCommand(identifier: "noop", title: "No-op") { text, selection in
            (text, selection)
        }
        let registry = CommandRegistry(commands: [command])
        XCTAssertEqual(registry.commands.count, 1)
        XCTAssertNotNil(registry.command(for: "noop"))
        let result = registry.execute("noop", text: "abc", selection: NSRange(location: 1, length: 1))
        XCTAssertEqual(result?.text, "abc")
        XCTAssertEqual(result?.selection, NSRange(location: 1, length: 1))
    }

    // MARK: - Duplicate line

    func testDuplicateMiddleLine() {
        assertCommand("duplicate-line",
                      text: "one\ntwo\nthree",
                      selection: NSRange(location: 4, length: 0),
                      expectedText: "one\ntwo\ntwo\nthree",
                      expectedSelection: NSRange(location: 8, length: 0))
    }

    func testDuplicateFirstLine() {
        assertCommand("duplicate-line",
                      text: "a\nb",
                      selection: NSRange(location: 0, length: 0),
                      expectedText: "a\na\nb",
                      expectedSelection: NSRange(location: 2, length: 0))
    }

    func testDuplicateLastLineWithoutTrailingNewline() {
        assertCommand("duplicate-line",
                      text: "a\nb",
                      selection: NSRange(location: 2, length: 0),
                      expectedText: "a\nb\nb",
                      expectedSelection: NSRange(location: 4, length: 0))
    }

    func testDuplicateLastLineWithTrailingNewline() {
        assertCommand("duplicate-line",
                      text: "a\nb\n",
                      selection: NSRange(location: 2, length: 0),
                      expectedText: "a\nb\nb\n",
                      expectedSelection: NSRange(location: 4, length: 0))
    }

    func testDuplicateMultipleSelectedLines() {
        assertCommand("duplicate-line",
                      text: "a\nb\nc\nd\n",
                      selection: NSRange(location: 2, length: 4),
                      expectedText: "a\nb\nc\nb\nc\nd\n",
                      expectedSelection: NSRange(location: 6, length: 4))
    }

    func testDuplicateSelectionEndingAtNextLineStartDoesNotIncludeThatLine() {
        assertCommand("duplicate-line",
                      text: "a\nb\nc",
                      selection: NSRange(location: 0, length: 2),
                      expectedText: "a\na\nb\nc",
                      expectedSelection: NSRange(location: 2, length: 2))
    }

    func testDuplicateEmptyDocument() {
        assertCommand("duplicate-line",
                      text: "",
                      selection: NSRange(location: 0, length: 0),
                      expectedText: "\n",
                      expectedSelection: NSRange(location: 1, length: 0))
    }

    func testDuplicateUsesUTF16Offsets() {
        assertCommand("duplicate-line",
                      text: "😀\nb",
                      selection: NSRange(location: 0, length: 0),
                      expectedText: "😀\n😀\nb",
                      expectedSelection: NSRange(location: 3, length: 0))
    }

    func testDuplicateClampsOutOfBoundsSelection() {
        assertCommand("duplicate-line",
                      text: "a\nb",
                      selection: NSRange(location: 100, length: 5),
                      expectedText: "a\nb\nb",
                      expectedSelection: NSRange(location: 5, length: 0))
    }

    // MARK: - Delete line

    func testDeleteMiddleLine() {
        assertCommand("delete-line",
                      text: "a\nb\nc",
                      selection: NSRange(location: 2, length: 0),
                      expectedText: "a\nc",
                      expectedSelection: NSRange(location: 2, length: 0))
    }

    func testDeleteFirstLine() {
        assertCommand("delete-line",
                      text: "a\nb\nc",
                      selection: NSRange(location: 0, length: 0),
                      expectedText: "b\nc",
                      expectedSelection: NSRange(location: 0, length: 0))
    }

    func testDeleteLastLineWithoutTrailingNewline() {
        assertCommand("delete-line",
                      text: "a\nb\nc",
                      selection: NSRange(location: 4, length: 0),
                      expectedText: "a\nb",
                      expectedSelection: NSRange(location: 3, length: 0))
    }

    func testDeleteLastLineWithTrailingNewline() {
        assertCommand("delete-line",
                      text: "a\nb\n",
                      selection: NSRange(location: 2, length: 0),
                      expectedText: "a\n",
                      expectedSelection: NSRange(location: 2, length: 0))
    }

    func testDeleteOnlyLine() {
        assertCommand("delete-line",
                      text: "abc",
                      selection: NSRange(location: 1, length: 0),
                      expectedText: "",
                      expectedSelection: NSRange(location: 0, length: 0))
    }

    func testDeleteMultipleSelectedLines() {
        assertCommand("delete-line",
                      text: "a\nb\nc\nd\n",
                      selection: NSRange(location: 2, length: 4),
                      expectedText: "a\nd\n",
                      expectedSelection: NSRange(location: 2, length: 0))
    }

    func testDeleteTrailingEmptyLine() {
        assertCommand("delete-line",
                      text: "a\n",
                      selection: NSRange(location: 2, length: 0),
                      expectedText: "a",
                      expectedSelection: NSRange(location: 1, length: 0))
    }

    func testDeleteLastLineWithCRLF() {
        assertCommand("delete-line",
                      text: "a\r\nb",
                      selection: NSRange(location: 3, length: 0),
                      expectedText: "a",
                      expectedSelection: NSRange(location: 1, length: 0))
    }

    func testDeleteSelectionEndingAtNextLineStartDoesNotDeleteNextLine() {
        assertCommand("delete-line",
                      text: "a\nb",
                      selection: NSRange(location: 0, length: 2),
                      expectedText: "b",
                      expectedSelection: NSRange(location: 0, length: 0))
    }

    // MARK: - Move line up

    func testMoveMiddleLineUp() {
        assertCommand("move-line-up",
                      text: "a\nb\nc",
                      selection: NSRange(location: 2, length: 0),
                      expectedText: "b\na\nc",
                      expectedSelection: NSRange(location: 0, length: 0))
    }

    func testMoveMultipleSelectedLinesUp() {
        assertCommand("move-line-up",
                      text: "a\nb\nc\nd",
                      selection: NSRange(location: 2, length: 3),
                      expectedText: "b\nc\na\nd",
                      expectedSelection: NSRange(location: 0, length: 3))
    }

    func testMoveFirstLineUpIsNoOp() {
        assertCommand("move-line-up",
                      text: "a\nb",
                      selection: NSRange(location: 0, length: 0),
                      expectedText: "a\nb",
                      expectedSelection: NSRange(location: 0, length: 0))
    }

    func testMoveLineUpPreservesSelectionWithinFirstLine() {
        assertCommand("move-line-up",
                      text: "abc\ndef",
                      selection: NSRange(location: 1, length: 1),
                      expectedText: "abc\ndef",
                      expectedSelection: NSRange(location: 1, length: 1))
    }

    func testMoveLastLineWithoutTrailingNewlineUp() {
        assertCommand("move-line-up",
                      text: "a\nb",
                      selection: NSRange(location: 2, length: 0),
                      expectedText: "b\na",
                      expectedSelection: NSRange(location: 0, length: 0))
    }

    func testMoveLineUpWithCRLF() {
        assertCommand("move-line-up",
                      text: "a\r\nb\r\nc",
                      selection: NSRange(location: 3, length: 0),
                      expectedText: "b\r\na\r\nc",
                      expectedSelection: NSRange(location: 0, length: 0))
    }

    func testMoveLineUpSelectionEndingAtNextLineStartDoesNotIncludeThatLine() {
        assertCommand("move-line-up",
                      text: "a\nb\nc",
                      selection: NSRange(location: 2, length: 2),
                      expectedText: "b\na\nc",
                      expectedSelection: NSRange(location: 0, length: 2))
    }

    // MARK: - Move line down

    func testMoveFirstLineDown() {
        assertCommand("move-line-down",
                      text: "a\nb\nc",
                      selection: NSRange(location: 0, length: 0),
                      expectedText: "b\na\nc",
                      expectedSelection: NSRange(location: 2, length: 0))
    }

    func testMoveMultipleSelectedLinesDown() {
        assertCommand("move-line-down",
                      text: "a\nb\nc\nd",
                      selection: NSRange(location: 2, length: 3),
                      expectedText: "a\nd\nb\nc",
                      expectedSelection: NSRange(location: 4, length: 3))
    }

    func testMoveLastLineDownIsNoOp() {
        assertCommand("move-line-down",
                      text: "a\nb",
                      selection: NSRange(location: 2, length: 0),
                      expectedText: "a\nb",
                      expectedSelection: NSRange(location: 2, length: 0))
    }

    func testMoveLineDownWhenBlockReachesEndOfTextIsNoOp() {
        assertCommand("move-line-down",
                      text: "a\n",
                      selection: NSRange(location: 0, length: 0),
                      expectedText: "a\n",
                      expectedSelection: NSRange(location: 0, length: 0))
    }

    func testMoveAdjacentLastLineWithoutTrailingNewlineDown() {
        assertCommand("move-line-down",
                      text: "a\nb",
                      selection: NSRange(location: 0, length: 0),
                      expectedText: "b\na",
                      expectedSelection: NSRange(location: 2, length: 0))
    }

    func testMoveLineDownWithCRLF() {
        assertCommand("move-line-down",
                      text: "a\r\nb\r\nc",
                      selection: NSRange(location: 0, length: 0),
                      expectedText: "b\r\na\r\nc",
                      expectedSelection: NSRange(location: 3, length: 0))
    }

    func testMoveLineDownSelectionEndingAtNextLineStartDoesNotIncludeThatLine() {
        assertCommand("move-line-down",
                      text: "a\nb\nc",
                      selection: NSRange(location: 0, length: 2),
                      expectedText: "b\na\nc",
                      expectedSelection: NSRange(location: 2, length: 2))
    }

    // MARK: - Toggle line comment

    func testToggleCommentsSingleLine() {
        assertCommand("toggle-line-comment",
                      text: "abc",
                      selection: NSRange(location: 0, length: 0),
                      expectedText: "//abc",
                      expectedSelection: NSRange(location: 2, length: 0))
    }

    func testToggleCommentsIndentedLine() {
        assertCommand("toggle-line-comment",
                      text: "    abc",
                      selection: NSRange(location: 6, length: 0),
                      expectedText: "    //abc",
                      expectedSelection: NSRange(location: 8, length: 0))
    }

    func testToggleRemovesCommentFromSingleLine() {
        assertCommand("toggle-line-comment",
                      text: "//abc",
                      selection: NSRange(location: 5, length: 0),
                      expectedText: "abc",
                      expectedSelection: NSRange(location: 3, length: 0))
    }

    func testToggleRemovesCommentsFromAllSelectedLines() {
        assertCommand("toggle-line-comment",
                      text: "//a\n  //b",
                      selection: NSRange(location: 0, length: 9),
                      expectedText: "a\n  b",
                      expectedSelection: NSRange(location: 0, length: 5))
    }

    func testToggleWithMixedSelectionCommentsEveryLine() {
        assertCommand("toggle-line-comment",
                      text: "//a\nb",
                      selection: NSRange(location: 0, length: 5),
                      expectedText: "////a\n//b",
                      expectedSelection: NSRange(location: 0, length: 9))
    }

    func testToggleSkipsBlankLines() {
        assertCommand("toggle-line-comment",
                      text: "a\n\nb",
                      selection: NSRange(location: 0, length: 4),
                      expectedText: "//a\n\n//b",
                      expectedSelection: NSRange(location: 0, length: 8))
    }

    func testToggleOnBlankLinesIsNoOp() {
        assertCommand("toggle-line-comment",
                      text: "  \n\t",
                      selection: NSRange(location: 0, length: 4),
                      expectedText: "  \n\t",
                      expectedSelection: NSRange(location: 0, length: 4))
    }

    func testToggleSelectionEndingAtNextLineStartDoesNotCommentThatLine() {
        assertCommand("toggle-line-comment",
                      text: "a\nb\nc",
                      selection: NSRange(location: 0, length: 2),
                      expectedText: "//a\nb\nc",
                      expectedSelection: NSRange(location: 0, length: 4))
    }

    func testToggleCommentsLastLineWithoutTrailingNewline() {
        assertCommand("toggle-line-comment",
                      text: "a\nb",
                      selection: NSRange(location: 2, length: 1),
                      expectedText: "a\n//b",
                      expectedSelection: NSRange(location: 2, length: 3))
    }

    func testToggleTwiceRestoresOriginalText() {
        let first = assertCommand("toggle-line-comment",
                                  text: "  abc",
                                  selection: NSRange(location: 2, length: 0),
                                  expectedText: "  //abc",
                                  expectedSelection: NSRange(location: 4, length: 0))
        guard let first else { return }
        assertCommand("toggle-line-comment",
                      text: first.text,
                      selection: first.selection,
                      expectedText: "  abc",
                      expectedSelection: NSRange(location: 2, length: 0))
    }

    func testToggleWithCustomPrefixWithIndentation() {
        let result = LineOps.toggleLineComment("  # x", selection: NSRange(location: 2, length: 0), prefix: "# ")
        XCTAssertEqual(result.text, "  x")
        XCTAssertEqual(result.selection, NSRange(location: 2, length: 0))
    }

    func testToggleWithEmptyPrefixIsNoOp() {
        let selection = NSRange(location: 1, length: 0)
        let result = LineOps.toggleLineComment("abc", selection: selection, prefix: "")
        XCTAssertEqual(result.text, "abc")
        XCTAssertEqual(result.selection, selection)
    }

    // MARK: - Uppercase / lowercase

    func testUppercaseSelection() {
        assertCommand("uppercase",
                      text: "hello world",
                      selection: NSRange(location: 0, length: 5),
                      expectedText: "HELLO world",
                      expectedSelection: NSRange(location: 0, length: 5))
    }

    func testUppercaseWithoutSelectionIsNoOp() {
        assertCommand("uppercase",
                      text: "hello",
                      selection: NSRange(location: 2, length: 0),
                      expectedText: "hello",
                      expectedSelection: NSRange(location: 2, length: 0))
    }

    func testUppercaseMultiLineSelection() {
        assertCommand("uppercase",
                      text: "abc\ndef",
                      selection: NSRange(location: 0, length: 7),
                      expectedText: "ABC\nDEF",
                      expectedSelection: NSRange(location: 0, length: 7))
    }

    func testLowercaseSelection() {
        assertCommand("lowercase",
                      text: "ABC\nDEF",
                      selection: NSRange(location: 4, length: 3),
                      expectedText: "ABC\ndef",
                      expectedSelection: NSRange(location: 4, length: 3))
    }

    func testLowercaseWithoutSelectionIsNoOp() {
        assertCommand("lowercase",
                      text: "ABC",
                      selection: NSRange(location: 1, length: 0),
                      expectedText: "ABC",
                      expectedSelection: NSRange(location: 1, length: 0))
    }

    func testUppercaseAdjustsSelectionLengthForExpandingCharacters() {
        assertCommand("uppercase",
                      text: "straße",
                      selection: NSRange(location: 0, length: 6),
                      expectedText: "STRASSE",
                      expectedSelection: NSRange(location: 0, length: 7))
    }

    func testUppercasePreservesUTF16OffsetsWithEmoji() {
        assertCommand("uppercase",
                      text: "a😀b",
                      selection: NSRange(location: 0, length: 4),
                      expectedText: "A😀B",
                      expectedSelection: NSRange(location: 0, length: 4))
    }

    func testCaseCommandsClampOutOfBoundsSelection() {
        assertCommand("uppercase",
                      text: "abc",
                      selection: NSRange(location: 1, length: 100),
                      expectedText: "aBC",
                      expectedSelection: NSRange(location: 1, length: 2))
    }

    func testCaseCommandWithNSNotFoundSelectionIsNoOp() {
        assertCommand("lowercase",
                      text: "ABC",
                      selection: NSRange(location: NSNotFound, length: 0),
                      expectedText: "ABC",
                      expectedSelection: NSRange(location: 0, length: 0))
    }

    // MARK: - LineOps parity

    func testEveryDefaultCommandMatchesItsLineOpsImplementation() {
        let text = "one\ntwo\nthree"
        let selection = NSRange(location: 4, length: 2)

        let expected: [String: (text: String, selection: NSRange)] = [
            "duplicate-line": LineOps.duplicateLine(text, selection: selection),
            "delete-line": LineOps.deleteLine(text, selection: selection),
            "move-line-up": LineOps.moveLineUp(text, selection: selection),
            "move-line-down": LineOps.moveLineDown(text, selection: selection),
            "toggle-line-comment": LineOps.toggleLineComment(text, selection: selection),
            "uppercase": LineOps.uppercase(text, selection: selection),
            "lowercase": LineOps.lowercase(text, selection: selection)
        ]

        for (identifier, expectedResult) in expected {
            let result = CommandRegistry.default.execute(identifier, text: text, selection: selection)
            XCTAssertEqual(result?.text, expectedResult.text, identifier)
            XCTAssertEqual(result?.selection, expectedResult.selection, identifier)
        }
    }
}
