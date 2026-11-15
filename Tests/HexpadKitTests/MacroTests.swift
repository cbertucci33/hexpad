import XCTest
@testable import HexpadKit

final class MacroTests: XCTestCase {

    // MARK: - Recording and replay

    func testRecordAndReplayRoundTrip() {
        var macro = MacroModel()
        macro.startRecording(name: "Duplicate and Comment")
        XCTAssertTrue(macro.isRecording)

        XCTAssertTrue(macro.record("duplicate-line"))
        XCTAssertTrue(macro.record("toggle-line-comment", parameter: "# "))
        macro.stopRecording()
        XCTAssertFalse(macro.isRecording)

        XCTAssertEqual(macro.name, "Duplicate and Comment")
        XCTAssertEqual(macro.steps, [
            MacroStep(identifier: "duplicate-line"),
            MacroStep(identifier: "toggle-line-comment", parameter: "# ")
        ])

        // The registry's configured prefix is `//`; the recorded parameter must
        // win so the replay matches what was recorded.
        let result = macro.replay(using: CommandRegistry(),
                                  text: "alpha\nbeta",
                                  selection: NSRange(location: 0, length: 0))

        XCTAssertEqual(result.text, "alpha\n# alpha\nbeta")
        XCTAssertEqual(result.selection, NSRange(location: 8, length: 0))
        XCTAssertEqual(result.stepResults.map(\.outcome), [.applied, .applied])
        XCTAssertEqual(result.appliedCount, 2)
        XCTAssertEqual(result.skippedCount, 0)
        XCTAssertTrue(result.skippedSteps.isEmpty)
        XCTAssertTrue(result.isFullyApplied)
    }

    func testReplaySkipsInapplicableStepAndContinues() {
        let macro = MacroModel(name: "Best Effort", steps: [
            MacroStep(identifier: "duplicate-line"),
            // Uppercase needs a non-empty selection; with a caret it is a no-op.
            MacroStep(identifier: "uppercase"),
            MacroStep(identifier: "toggle-line-comment", parameter: "# ")
        ])

        let result = macro.replay(using: CommandRegistry(),
                                  text: "one\ntwo",
                                  selection: NSRange(location: 0, length: 0))

        XCTAssertEqual(result.text, "one\n# one\ntwo")
        XCTAssertEqual(result.selection, NSRange(location: 6, length: 0))
        XCTAssertEqual(result.stepResults.count, 3)
        XCTAssertEqual(result.stepResults[0].outcome, .applied)
        XCTAssertEqual(result.stepResults[1].outcome, .skipped(.noChange))
        XCTAssertEqual(result.stepResults[2].outcome, .applied)
        XCTAssertEqual(result.appliedCount, 2)
        XCTAssertEqual(result.skippedCount, 1)
        XCTAssertFalse(result.isFullyApplied)
        XCTAssertEqual(result.skippedSteps.map(\.index), [1])
        XCTAssertEqual(result.skippedSteps.first?.skipReason, .noChange)
        XCTAssertEqual(MacroSkipReason.noChange.description, "command made no change")
    }

    func testReplaySkipsUnknownCommandAndContinues() {
        let macro = MacroModel(name: "Unknown", steps: [
            MacroStep(identifier: "not-a-command"),
            MacroStep(identifier: "duplicate-line")
        ])

        let result = macro.replay(using: CommandRegistry(),
                                  text: "a",
                                  selection: NSRange(location: 0, length: 0))

        XCTAssertEqual(result.text, "a\na")
        XCTAssertEqual(result.selection, NSRange(location: 2, length: 0))
        XCTAssertEqual(result.stepResults[0].outcome, .skipped(.unknownCommand))
        XCTAssertEqual(result.stepResults[1].outcome, .applied)
        XCTAssertEqual(MacroSkipReason.unknownCommand.description, "unknown command")
    }

    // MARK: - Recording rules

    func testRecordingOnlyAppendsWhileActiveAndResetsOnRestart() {
        var macro = MacroModel()
        XCTAssertFalse(macro.record("duplicate-line"))
        XCTAssertTrue(macro.isEmpty)

        macro.startRecording(name: "First")
        XCTAssertTrue(macro.record("duplicate-line"))
        XCTAssertTrue(macro.record("uppercase"))
        macro.stopRecording()
        XCTAssertFalse(macro.record("delete-line"))
        XCTAssertEqual(macro.steps.count, 2)

        macro.startRecording(name: "Second")
        XCTAssertEqual(macro.name, "Second")
        XCTAssertTrue(macro.steps.isEmpty)
        XCTAssertTrue(macro.record("delete-line"))
        macro.stopRecording()
        XCTAssertEqual(macro.steps, [MacroStep(identifier: "delete-line")])
    }

    // MARK: - Codable

    func testCodableRoundTrip() throws {
        let original = MacroModel(name: "Commenter", steps: [
            MacroStep(identifier: "toggle-line-comment", parameter: "// "),
            MacroStep(identifier: "move-line-down")
        ])

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MacroModel.self, from: data)

        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.name, "Commenter")
        XCTAssertEqual(decoded.steps, original.steps)
        XCTAssertFalse(decoded.isRecording)

        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains("\"name\""))
        XCTAssertTrue(json.contains("\"steps\""))
        XCTAssertFalse(json.contains("isRecording"))
    }

    func testDecodingMissingKeysFallsBackToDefaults() throws {
        let decoded = try JSONDecoder().decode(MacroModel.self,
                                               from: Data("{}".utf8))
        XCTAssertEqual(decoded.name, "Macro")
        XCTAssertTrue(decoded.steps.isEmpty)
        XCTAssertFalse(decoded.isRecording)
    }

    // MARK: - Edge cases

    func testEmptyMacroLeavesDocumentUnchanged() {
        let macro = MacroModel(name: "Empty")
        let selection = NSRange(location: 1, length: 1)

        XCTAssertTrue(macro.isEmpty)
        XCTAssertEqual(macro.stepCount, 0)

        let result = macro.replay(using: .default, text: "a\nb", selection: selection)

        XCTAssertEqual(result.text, "a\nb")
        XCTAssertEqual(result.selection, selection)
        XCTAssertTrue(result.stepResults.isEmpty)
        XCTAssertEqual(result.appliedCount, 0)
        XCTAssertEqual(result.skippedCount, 0)
        XCTAssertTrue(result.isFullyApplied)
    }

    func testReplayOnEmptyDocument() {
        let macro = MacroModel(name: "Blank Start", steps: [
            MacroStep(identifier: "duplicate-line"),
            MacroStep(identifier: "toggle-line-comment", parameter: "//")
        ])

        let result = macro.replay(using: CommandRegistry(),
                                  text: "",
                                  selection: NSRange(location: 0, length: 0))

        // Duplicating the single empty line creates one line; there is nothing
        // to comment on a blank line, so the second step is skipped.
        XCTAssertEqual(result.text, "\n")
        XCTAssertEqual(result.selection, NSRange(location: 1, length: 0))
        XCTAssertEqual(result.stepResults[0].outcome, .applied)
        XCTAssertEqual(result.stepResults[1].outcome, .skipped(.noChange))
    }

    func testEmptyMacroOnEmptyDocumentIsUnchanged() {
        let macro = MacroModel()
        let result = macro.replay(using: CommandRegistry(),
                                  text: "",
                                  selection: NSRange(location: 0, length: 0))
        XCTAssertEqual(result.text, "")
        XCTAssertEqual(result.selection, NSRange(location: 0, length: 0))
        XCTAssertTrue(result.stepResults.isEmpty)
    }
}
