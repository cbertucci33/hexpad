import XCTest
@testable import HexpadKit

final class IndentOpsTests: XCTestCase {

    // MARK: - Increase indent

    func testIndentUsesSpacesPolicyOnEverySelectedLine() {
        let text = "one\ntwo\nthree"
        let result = IndentOps.indentLines(text,
                                           selection: NSRange(location: 0, length: 7),
                                           tabSize: 2,
                                           useTabs: false)

        XCTAssertEqual(result.text, "  one\n  two\nthree")
        XCTAssertEqual(result.selection, NSRange(location: 0, length: 11))
    }

    func testIndentUsesTabsPolicyAndPreservesRelativeIndentation() {
        let text = "a\n  b"
        let result = IndentOps.indentLines(text,
                                           selection: NSRange(location: 0, length: 5),
                                           tabSize: 4,
                                           useTabs: true)

        XCTAssertEqual(result.text, "\ta\n\t  b")
        XCTAssertEqual(result.selection, NSRange(location: 0, length: 7))
    }

    func testCollapsedSelectionIndentsOnlyTheCaretLine() {
        let result = IndentOps.indentLines("a\nb\nc",
                                           selection: NSRange(location: 2, length: 0),
                                           tabSize: 4,
                                           useTabs: false)

        XCTAssertEqual(result.text, "a\n    b\nc")
        XCTAssertEqual(result.selection, NSRange(location: 6, length: 0))
    }

    func testSelectionEndingAtNextLineStartDoesNotIndentThatLine() {
        let result = IndentOps.indentLines("a\nb\nc",
                                           selection: NSRange(location: 0, length: 2),
                                           tabSize: 2,
                                           useTabs: false)

        XCTAssertEqual(result.text, "  a\nb\nc")
        XCTAssertEqual(result.selection, NSRange(location: 0, length: 4))
    }

    // MARK: - Decrease indent

    func testDedentRemovesOnlyOneLevelAndKeepsRelativeIndentation() {
        let text = "        one\n    two\n  three\nfour"
        let result = IndentOps.dedentLines(text,
                                           selection: NSRange(location: 0, length: 32),
                                           tabSize: 4,
                                           useTabs: false)

        XCTAssertEqual(result.text, "    one\ntwo\nthree\nfour")
        XCTAssertEqual(result.selection, NSRange(location: 0, length: 22))
    }

    func testDedentWithTabsRemovesOneTabPerLine() {
        let result = IndentOps.dedentLines("\t\tone\n\t two\none",
                                           selection: NSRange(location: 0, length: 15),
                                           tabSize: 4,
                                           useTabs: true)

        XCTAssertEqual(result.text, "\tone\n two\none")
    }

    func testDedentWithSpacesPolicyAlsoRemovesALeadingTabAsOneLevel() {
        let result = IndentOps.dedentLines("\tone\n  two",
                                           selection: NSRange(location: 0, length: 10),
                                           tabSize: 4,
                                           useTabs: false)

        XCTAssertEqual(result.text, "one\ntwo")
    }

    func testDedentNeverStripsMoreThanOneLevel() {
        let result = IndentOps.dedentLines("            x",
                                           selection: NSRange(location: 0, length: 0),
                                           tabSize: 4,
                                           useTabs: false)

        XCTAssertEqual(result.text, "        x")
    }

    func testDedentLineWithoutIndentationIsANoOp() {
        let result = IndentOps.dedentLines("alpha\n  beta",
                                           selection: NSRange(location: 0, length: 0),
                                           tabSize: 4,
                                           useTabs: false)

        XCTAssertEqual(result.text, "alpha\n  beta")
        XCTAssertEqual(result.selection, NSRange(location: 0, length: 0))
    }

    func testDedentMapsSelectionToTheSameLines() {
        let result = IndentOps.dedentLines("    a\n    b\nc",
                                           selection: NSRange(location: 0, length: 11),
                                           tabSize: 4,
                                           useTabs: false)

        XCTAssertEqual(result.text, "a\nb\nc")
        XCTAssertEqual(result.selection, NSRange(location: 0, length: 3))
    }

    func testCaretInsideRemovedIndentationClampsToLineStart() {
        let result = IndentOps.dedentLines("    a",
                                           selection: NSRange(location: 2, length: 0),
                                           tabSize: 4,
                                           useTabs: false)

        XCTAssertEqual(result.text, "a")
        XCTAssertEqual(result.selection, NSRange(location: 0, length: 0))
    }

    // MARK: - Settings

    func testIndentSettingsRoundTripThroughMacroParameter() {
        XCTAssertEqual(IndentSettings(parameter: "tabs:2"), IndentSettings(tabSize: 2, useTabs: true))
        XCTAssertEqual(IndentSettings(parameter: "spaces:8"), IndentSettings(tabSize: 8, useTabs: false))
        XCTAssertNil(IndentSettings(parameter: "tabs:zero"))
        XCTAssertNil(IndentSettings(parameter: "wat"))
        XCTAssertEqual(IndentSettings(tabSize: 0).tabSize, 1)
    }

    // MARK: - Registry

    func testIndentCommandsAreRegisteredInMenuOrder() {
        XCTAssertEqual(CommandRegistry.default.indentCommands.map(\.identifier), [
            "indent-increase",
            "indent-decrease"
        ])
        XCTAssertEqual(CommandRegistry.default.indentCommands.map(\.title), [
            "Increase Line Indent",
            "Decrease Line Indent"
        ])
    }

    func testIndentCommandsArePartOfAllCommands() {
        let ids = CommandRegistry.default.allCommands.map(\.identifier)
        for id in CommandRegistry.default.indentCommands.map(\.identifier) {
            XCTAssertTrue(ids.contains(id), "missing \(id) from allCommands")
        }
    }

    func testRegistryPassesThePreferencesPolicyAsAParameter() {
        let registry = CommandRegistry.default

        let tabs = registry.execute("indent-increase",
                                    parameter: "tabs:2",
                                    text: "a\nb",
                                    selection: NSRange(location: 0, length: 0))
        XCTAssertEqual(tabs?.text, "\ta\nb")
        XCTAssertEqual(tabs?.selection, NSRange(location: 1, length: 0))

        let spaces = registry.execute("indent-increase",
                                      parameter: "spaces:2",
                                      text: "a\nb",
                                      selection: NSRange(location: 0, length: 0))
        XCTAssertEqual(spaces?.text, "  a\nb")
        XCTAssertEqual(spaces?.selection, NSRange(location: 2, length: 0))

        let dedented = registry.execute("indent-decrease",
                                        parameter: "tabs:4",
                                        text: "\ta\n\tb",
                                        selection: NSRange(location: 0, length: 5))
        XCTAssertEqual(dedented?.text, "a\nb")
        XCTAssertEqual(dedented?.selection, NSRange(location: 0, length: 3))
    }

    func testRegistryFallsBackToItsConfiguredPolicy() {
        let registry = CommandRegistry(indentSettings: IndentSettings(tabSize: 2, useTabs: true))
        let result = registry.execute("indent-increase",
                                      text: "a",
                                      selection: NSRange(location: 0, length: 0))

        XCTAssertEqual(result?.text, "\ta")
        XCTAssertEqual(result?.selection, NSRange(location: 1, length: 0))
    }

    func testUnknownParameterFallsBackToTheCommandPolicy() {
        let result = CommandRegistry.default.execute("indent-increase",
                                                     parameter: "not-a-policy",
                                                     text: "a",
                                                     selection: NSRange(location: 0, length: 0))

        XCTAssertEqual(result?.text, "    a")
    }

    func testRegistryIndentThroughDocumentModelIsASingleUndoStep() {
        let doc = DocumentModel(text: "a\nb\nc")
        doc.undoManager.removeAllActions()

        let result = CommandRegistry.default.execute("indent-increase",
                                                     parameter: "spaces:2",
                                                     text: doc.text,
                                                     selection: NSRange(location: 0, length: 5))
        XCTAssertEqual(result?.text, "  a\n  b\n  c")

        doc.replaceAllText(with: result?.text ?? doc.text)
        XCTAssertEqual(doc.text, "  a\n  b\n  c")
        XCTAssertTrue(doc.undoManager.canUndo)

        doc.undoManager.undo()
        XCTAssertEqual(doc.text, "a\nb\nc")
    }
}
