import XCTest
@testable import HexpadKit

/// P17g-2: pure Search > Begin/End Select toggle semantics.
///
/// The editor keeps the anchor as per-view UI state, but the anchor/complete
/// cycle itself is a Kit-side model so it can be driven headlessly: a bare
/// caret anchors an empty range, an existing selection anchors its whole range,
/// completion joins anchor and caret (or builds the two column corners), and
/// anything that is not the command cancels a pending anchor.
final class BeginEndSelectTests: XCTestCase {

    private func point(_ line: Int, _ column: Int) -> TextPoint {
        TextPoint(line: line, column: column)
    }

    // MARK: - Begin half

    func testFirstPressAnchorsBareCaret() {
        var state = BeginEndSelectState()
        let caret = NSRange(location: 5, length: 0)

        let completion = state.toggle(selection: caret, point: point(1, 2), columnMode: false)

        XCTAssertNil(completion, "the Begin half changes no selection")
        XCTAssertEqual(state.anchor?.range, caret)
        XCTAssertEqual(state.anchor?.point, point(1, 2))
        XCTAssertEqual(state.anchor?.columnMode, false)
    }

    func testFirstPressWithExistingSelectionAnchorsWholeRange() {
        var state = BeginEndSelectState()
        let selection = NSRange(location: 3, length: 5)

        state.begin(selection: selection, point: point(0, 3), columnMode: false)

        XCTAssertEqual(state.anchor?.range, selection,
                       "N++ anchors the active range when Begin is pressed with a selection")
    }

    // MARK: - Complete half

    func testCompletionUnionsAnchorAndCaretAndClearsAnchor() {
        var state = BeginEndSelectState()
        state.begin(selection: NSRange(location: 3, length: 0),
                    point: point(0, 3),
                    columnMode: false)

        let completion = state.complete(selection: NSRange(location: 12, length: 0),
                                        point: point(1, 5))

        XCTAssertEqual(completion, .range(NSRange(location: 3, length: 9)))
        XCTAssertNil(state.anchor, "a completed cycle consumes its anchor")
    }

    func testCompletionWithAnchoredSelectionUsesItsFullSpan() {
        var state = BeginEndSelectState()
        state.begin(selection: NSRange(location: 2, length: 4),
                    point: point(0, 2),
                    columnMode: false)

        let completion = state.complete(selection: NSRange(location: 11, length: 0),
                                        point: point(1, 4))

        XCTAssertEqual(completion, .range(NSRange(location: 2, length: 9)))
    }

    func testColumnCompletionReturnsTheTwoAnchoredCorners() {
        var state = BeginEndSelectState()
        let anchorPoint = point(0, 1)
        state.begin(selection: NSRange(location: 1, length: 0),
                    point: anchorPoint,
                    columnMode: true)

        let caretPoint = point(3, 4)
        let completion = state.complete(selection: NSRange(location: 20, length: 0),
                                        point: caretPoint)

        XCTAssertEqual(completion, .column(anchorPoint, caretPoint))
        XCTAssertNil(state.anchor)
    }

    func testMixedCompletingPressUsesTheModeTheCycleBeganIn() {
        var state = BeginEndSelectState()
        let anchorPoint = point(0, 2)
        state.begin(selection: NSRange(location: 2, length: 0),
                    point: anchorPoint,
                    columnMode: true)

        // The Column Mode press completes the pending cycle; the mode is stored
        // on the anchor, not re-read from whichever command lands the press.
        let completion = state.toggle(selection: NSRange(location: 9, length: 0),
                                      point: point(1, 3),
                                      columnMode: false)

        XCTAssertEqual(completion, .column(anchorPoint, point(1, 3)))
    }

    // MARK: - Cancellation and no-ops

    func testSecondPressWithoutAnchorIsANoOp() {
        var state = BeginEndSelectState()

        XCTAssertNil(state.complete(selection: NSRange(location: 8, length: 0),
                                    point: point(1, 1)),
                     "the End half without a pending anchor changes nothing")
        XCTAssertNil(state.anchor)
    }

    func testCancelInvalidatesPendingAnchor() {
        var state = BeginEndSelectState()
        state.begin(selection: NSRange(location: 4, length: 0),
                    point: point(0, 4),
                    columnMode: false)
        XCTAssertNotNil(state.anchor)

        state.cancel()

        XCTAssertNil(state.complete(selection: NSRange(location: 10, length: 0),
                                    point: point(1, 2)))
    }

    func testToggleReArmsAfterACompletedCycle() {
        var state = BeginEndSelectState()
        state.toggle(selection: NSRange(location: 0, length: 0),
                     point: point(0, 0),
                     columnMode: false)
        XCTAssertNotNil(state.toggle(selection: NSRange(location: 6, length: 0),
                                     point: point(1, 2),
                                     columnMode: false))

        let newCaret = NSRange(location: 9, length: 0)
        XCTAssertNil(state.toggle(selection: newCaret, point: point(2, 1), columnMode: false),
                     "the press after completion begins a fresh cycle")
        XCTAssertEqual(state.anchor?.range, newCaret)
    }

    // MARK: - Registry wiring

    func testRegistryCarriesBothViewCommandsOutsideAllCommands() {
        let registry = CommandRegistry.default
        let expected: [(String, String)] = [
            ("begin-end-select", "Begin/End Select"),
            ("begin-end-select-column", "Begin/End Select in Column Mode")
        ]

        for (identifier, title) in expected {
            let command = registry.command(for: identifier)
            XCTAssertNotNil(command, identifier)
            XCTAssertEqual(command?.title, title)
            XCTAssertNotNil(command?.viewExecute, "\(identifier) is a view-only command")
            XCTAssertTrue(registry.beginEndSelectCommands.contains { $0.identifier == identifier })
            XCTAssertFalse(registry.multiSelectCommands.contains { $0.identifier == identifier },
                           "the P17g-1 group keeps its exact pinned shape")
            XCTAssertFalse(registry.allCommands.contains { $0.identifier == identifier },
                           "allCommands stays pinned to the legacy groups")
        }
    }

    func testViewHookForwardsThePinnedOperations() {
        var received: [BeginEndSelectOperation] = []
        var context = EditorCommandContext(beginEndSelect: { operation in
            received.append(operation)
            return operation == .column
        })
        let registry = CommandRegistry.default

        XCTAssertFalse(registry.executeView("begin-end-select", context: context) ?? false)
        XCTAssertTrue(registry.executeView("begin-end-select-column", context: context) ?? false)
        XCTAssertEqual(received, [.standard, .column])
        XCTAssertFalse(context.isEmpty)

        // A headless context (no hook) makes both commands safe no-ops.
        XCTAssertFalse(registry.executeView("begin-end-select",
                                            context: EditorCommandContext()) ?? true)
        XCTAssertFalse(registry.executeView("begin-end-select-column",
                                            context: EditorCommandContext()) ?? true)
    }
}
