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

    // MARK: - Tools and view command groups

    func testExtraCommandGroupsAreRegisteredInMenuOrder() {
        let registry = CommandRegistry.default
        XCTAssertEqual(registry.toolCommands.map(\.identifier), [
            "hash-md5", "hash-sha1", "hash-sha256",
            "insert-date", "insert-time", "insert-datetime"
        ])
        XCTAssertEqual(registry.lineOpCommands.map(\.identifier), [
            "sort-lines-ascending", "sort-lines-descending",
            "remove-duplicate-lines", "remove-blank-lines"
        ])
        XCTAssertEqual(registry.viewCommands.map(\.identifier), [
            "fold-all", "unfold-all", "fold-current-level", "unfold-current-level",
            "fold-level-1", "fold-level-2", "fold-level-3", "fold-level-4",
            "fold-level-5", "fold-level-6", "fold-level-7", "fold-level-8",
            "unfold-level-1", "unfold-level-2", "unfold-level-3", "unfold-level-4",
            "unfold-level-5", "unfold-level-6", "unfold-level-7", "unfold-level-8",
            "toggle-word-wrap"
        ])
        XCTAssertNotNil(registry.command(for: "hash-md5"))
        XCTAssertNotNil(registry.command(for: "insert-datetime"))
        XCTAssertNotNil(registry.command(for: "remove-blank-lines"))
        XCTAssertNotNil(registry.command(for: "fold-all"))
    }

    // MARK: - Hash commands

    func testHashCommandDigestsWholeBufferWhenCaretOnly() {
        let result = CommandRegistry.default.execute("hash-md5",
                                                     text: "abc",
                                                     selection: NSRange(location: 1, length: 0))
        XCTAssertEqual(result?.text, "a900150983cd24fb0d6963f7d28e17f72bc")
        XCTAssertEqual(result?.selection, NSRange(location: 33, length: 0))
    }

    func testHashCommandDigestsSelectionAndInsertsAtCaret() {
        let result = CommandRegistry.default.execute("hash-sha256",
                                                     text: "abc",
                                                     selection: NSRange(location: 0, length: 3))
        XCTAssertEqual(
            result?.text,
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015adabc"
        )
        XCTAssertEqual(result?.selection, NSRange(location: 64, length: 0))
    }

    func testHashCommandsCoverEveryAlgorithm() {
        XCTAssertNotNil(CommandRegistry.default.execute("hash-md5", text: "abc",
                                                        selection: NSRange(location: 0, length: 0)))
        XCTAssertNotNil(CommandRegistry.default.execute("hash-sha1", text: "abc",
                                                        selection: NSRange(location: 0, length: 0)))
        XCTAssertNotNil(CommandRegistry.default.execute("hash-sha256", text: "abc",
                                                        selection: NSRange(location: 0, length: 0)))
    }

    func testHashCommandTreatedOutOfRangeSelectionAsWholeBuffer() {
        let result = CommandRegistry.default.execute("hash-md5",
                                                     text: "abc",
                                                     selection: NSRange(location: 2, length: 100))
        XCTAssertEqual(result?.text, "ab" + HashKit.md5("abc") + "c")
        XCTAssertEqual(result?.selection, NSRange(location: 34, length: 0))
    }

    // MARK: - Date/time commands

    /// 2021-03-04 05:06:07 UTC, matching the Tools fixtures.
    private func fixedDate(second: Int = 7) throws -> Date {
        var components = DateComponents()
        components.year = 2021
        components.month = 3
        components.day = 4
        components.hour = 5
        components.minute = 6
        components.second = second

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        return try XCTUnwrap(calendar.date(from: components))
    }

    func testDateTimeCommandsUseTheInjectedClock() throws {
        let date = try fixedDate()
        let registry = CommandRegistry(now: { date })

        let expectedDate = DateTimeInsert.shortDate(date)
        let expectedTime = DateTimeInsert.shortTime(date)
        let expectedDateTime = DateTimeInsert.formatted(date, pattern: "yyyy-MM-dd HH:mm:ss")

        XCTAssertEqual(registry.execute("insert-date", text: "", selection: NSRange(location: 0, length: 0))?.text,
                       expectedDate)
        XCTAssertEqual(registry.execute("insert-time", text: "", selection: NSRange(location: 0, length: 0))?.text,
                       expectedTime)
        XCTAssertEqual(registry.execute("insert-datetime", text: "", selection: NSRange(location: 0, length: 0))?.text,
                       expectedDateTime)
    }

    func testClockIsReadAtExecutionTimeNotDefinitionTime() throws {
        var now = try fixedDate(second: 7)
        let registry = CommandRegistry(now: { now })

        let first = registry.execute("insert-datetime", text: "", selection: NSRange(location: 0, length: 0))?.text
        now = try fixedDate(second: 42)
        let second = registry.execute("insert-datetime", text: "", selection: NSRange(location: 0, length: 0))?.text

        let expectedFirst = DateTimeInsert.formatted(try fixedDate(second: 7),
                                                     pattern: "yyyy-MM-dd HH:mm:ss")
        let expectedSecond = DateTimeInsert.formatted(try fixedDate(second: 42),
                                                      pattern: "yyyy-MM-dd HH:mm:ss")
        XCTAssertEqual(first, expectedFirst)
        XCTAssertEqual(second, expectedSecond)
        XCTAssertNotEqual(first, second)
    }

    func testRecordedDateTimeReplayUsesAFreshTimestamp() throws {
        var now = try fixedDate(second: 7)
        let registry = CommandRegistry(now: { now })
        let macro = MacroModel(name: "Time", steps: [MacroStep(identifier: "insert-datetime")])

        let recorded = macro.replay(using: registry,
                                    text: "",
                                    selection: NSRange(location: 0, length: 0))
        now = try fixedDate(second: 42)
        let replayed = macro.replay(using: registry,
                                    text: "",
                                    selection: NSRange(location: 0, length: 0))

        let expectedRecorded = DateTimeInsert.formatted(try fixedDate(second: 7),
                                                        pattern: "yyyy-MM-dd HH:mm:ss")
        let expectedReplayed = DateTimeInsert.formatted(try fixedDate(second: 42),
                                                        pattern: "yyyy-MM-dd HH:mm:ss")
        XCTAssertEqual(recorded.text, expectedRecorded)
        XCTAssertEqual(replayed.text, expectedReplayed)
        XCTAssertNotEqual(recorded.text, replayed.text)
        XCTAssertEqual(replayed.stepResults.map(\.outcome), [.applied])
    }

    // MARK: - Line operation commands

    func testLineOpCommandTransformsWholeBufferWithoutSelection() {
        let result = CommandRegistry.default.execute("sort-lines-ascending",
                                                     text: "b\na",
                                                     selection: NSRange(location: 0, length: 0))
        XCTAssertEqual(result?.text, "a\nb")
        XCTAssertEqual(result?.selection, NSRange(location: 0, length: 0))
    }

    func testLineOpCommandTransformsOnlyTheSelection() {
        let result = CommandRegistry.default.execute("remove-blank-lines",
                                                     text: "a\n\nb",
                                                     selection: NSRange(location: 0, length: 3))
        // "a\n\n" loses its blank line, leaving "a"; the untouched "b" follows.
        XCTAssertEqual(result?.text, "ab")
        XCTAssertEqual(result?.selection, NSRange(location: 0, length: 1))
    }

    func testLineOpCommandsCoverEveryVariant() {
        let selection = NSRange(location: 0, length: 0)
        XCTAssertEqual(CommandRegistry.default.execute("sort-lines-descending",
                                                        text: "a\nb",
                                                        selection: selection)?.text, "b\na")
        XCTAssertEqual(CommandRegistry.default.execute("remove-duplicate-lines",
                                                        text: "a\na\nb",
                                                        selection: selection)?.text, "a\nb")
        XCTAssertEqual(CommandRegistry.default.execute("remove-blank-lines",
                                                        text: "a\n\nb",
                                                        selection: selection)?.text, "a\nb")
    }

    // MARK: - View commands

    func testViewCommandsRunThroughTheContextHooks() {
        var calls: [String] = []
        let context = EditorCommandContext(
            foldAll: { calls.append("fold"); return true },
            unfoldAll: { calls.append("unfold"); return true },
            toggleWordWrap: { calls.append("wrap"); return true }
        )

        XCTAssertEqual(CommandRegistry.default.executeView("fold-all", context: context), true)
        XCTAssertEqual(CommandRegistry.default.executeView("unfold-all", context: context), true)
        XCTAssertEqual(CommandRegistry.default.executeView("toggle-word-wrap", context: context), true)
        XCTAssertEqual(calls, ["fold", "unfold", "wrap"])
    }

    func testViewCommandWithoutHooksIsANoOp() {
        let context = EditorCommandContext()
        XCTAssertTrue(context.isEmpty)
        XCTAssertEqual(CommandRegistry.default.executeView("fold-all", context: context), false)
        XCTAssertEqual(CommandRegistry.default.executeView("fold-current-level", context: context), false)
        XCTAssertEqual(CommandRegistry.default.executeView("fold-level-1", context: context), false)
        XCTAssertEqual(CommandRegistry.default.executeView("unfold-level-8", context: context), false)
        XCTAssertNil(CommandRegistry.default.executeView("duplicate-line", context: context))
        XCTAssertNil(CommandRegistry.default.executeView("not-a-command", context: context))
    }

    func testFoldLevelCommandsForwardTheirDepthToTheHooks() {
        var calls: [String] = []
        let context = EditorCommandContext(
            foldCurrentLevel: { calls.append("fold-current"); return true },
            unfoldCurrentLevel: { calls.append("unfold-current"); return true },
            foldLevel: { calls.append("fold-\($0)"); return true },
            unfoldLevel: { calls.append("unfold-\($0)"); return true }
        )

        XCTAssertEqual(CommandRegistry.default.executeView("fold-current-level", context: context), true)
        XCTAssertEqual(CommandRegistry.default.executeView("unfold-current-level", context: context), true)
        XCTAssertEqual(CommandRegistry.default.executeView("fold-level-3", context: context), true)
        XCTAssertEqual(CommandRegistry.default.executeView("unfold-level-7", context: context), true)
        XCTAssertEqual(calls, ["fold-current", "unfold-current", "fold-3", "unfold-7"])
    }

    func testViewCommandsAreRecordedButReplaySkipsThemInPureTextReplay() {
        let macro = MacroModel(name: "Folded", steps: [
            MacroStep(identifier: "fold-all"),
            MacroStep(identifier: "duplicate-line")
        ])

        let result = macro.replay(using: CommandRegistry.default,
                                  text: "a",
                                  selection: NSRange(location: 0, length: 0))

        // fold-all is a real registered command, so it records like any other;
        // its effect is view state, which MacroModel's pure text replay cannot
        // express, so it is reported as a no-change skip rather than silently
        // pretending it ran.
        XCTAssertEqual(result.stepResults[0].outcome, .skipped(.noChange))
        XCTAssertEqual(result.stepResults[0].skipReason, .noChange)
        XCTAssertEqual(result.stepResults[1].outcome, .applied)
        XCTAssertEqual(result.text, "a\na")
        XCTAssertEqual(result.skippedCount, 1)
    }

    // MARK: - Macro round trip through the new command groups

    func testRecordedHashCommandReplaysAsTheSameDigest() {
        var macro = MacroModel()
        macro.startRecording()
        XCTAssertTrue(macro.record("hash-md5"))
        macro.stopRecording()

        let result = macro.replay(using: CommandRegistry.default,
                                  text: "abc",
                                  selection: NSRange(location: 0, length: 0))

        XCTAssertEqual(result.text, HashKit.md5("abc") + "abc")
        XCTAssertEqual(result.stepResults.map(\.outcome), [.applied])
    }
}
