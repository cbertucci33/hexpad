import XCTest
@testable import HexpadKit

final class MultiCaretTests: XCTestCase {

    // MARK: - State model

    func testCaretsAreKeptInDocumentOrder() {
        let state = MultiCaretState(carets: [
            NSRange(location: 10, length: 2),
            NSRange(location: 2, length: 1)
        ])

        XCTAssertEqual(state.carets, [
            NSRange(location: 2, length: 1),
            NSRange(location: 10, length: 2)
        ])
        XCTAssertTrue(state.isValid)
        XCTAssertEqual(state.count, 2)
    }

    func testOverlappingCaretsCollapseToOutermostRange() {
        let state = MultiCaretState(carets: [
            NSRange(location: 4, length: 4),   // 4..<8
            NSRange(location: 0, length: 3),   // 0..<3
            NSRange(location: 1, length: 2),   // 1..<3 overlaps the first
            NSRange(location: 6, length: 6)    // 6..<12 overlaps the second
        ])

        XCTAssertEqual(state.carets, [
            NSRange(location: 0, length: 3),
            NSRange(location: 4, length: 8)
        ])
        XCTAssertTrue(state.isValid)
    }

    func testDuplicateInsertionPointsCollapse() {
        let state = MultiCaretState(carets: [
            NSRange(location: 5, length: 0),
            NSRange(location: 5, length: 0),
            NSRange(location: 5, length: 0)
        ])

        XCTAssertEqual(state.carets, [NSRange(location: 5, length: 0)])
    }

    func testMergedBoundingRange() {
        let state = MultiCaretState(carets: [
            NSRange(location: 2, length: 2),   // 2..<4
            NSRange(location: 10, length: 4),  // 10..<14
            NSRange(location: 6, length: 1)    // 6..<7
        ])

        XCTAssertEqual(state.mergedBoundingRange, NSRange(location: 2, length: 12))
        XCTAssertNil(MultiCaretState().mergedBoundingRange)
    }

    func testAddRemoveToggleAndCollapse() {
        var state = MultiCaretState(caretAt: 5)
        state.addCaret(at: 1)
        state.addCaret(at: 9)

        XCTAssertEqual(state.carets.map(\.location), [1, 5, 9])
        XCTAssertEqual(state.primaryCaret, NSRange(location: 1, length: 0))

        state.toggleCaret(at: 5)
        XCTAssertEqual(state.carets.map(\.location), [1, 9])

        state.toggleCaret(at: 5)
        XCTAssertEqual(state.carets.map(\.location), [1, 5, 9])

        XCTAssertTrue(state.removeCaret(at: 1))
        XCTAssertFalse(state.removeCaret(at: 42))
        XCTAssertEqual(state.carets.map(\.location), [5, 9])

        state.collapseToPrimary()
        XCTAssertEqual(state.carets, [NSRange(location: 5, length: 0)])
        XCTAssertEqual(state.collapsedToPrimary().carets, [NSRange(location: 5, length: 0)])
    }

    func testToggleSelectionCaret() {
        var state = MultiCaretState(caret: NSRange(location: 2, length: 4))
        state.toggleCaret(NSRange(location: 2, length: 4))
        XCTAssertTrue(state.isEmpty)

        state.toggleCaret(NSRange(location: 2, length: 4))
        XCTAssertEqual(state.carets, [NSRange(location: 2, length: 4)])
    }

    // MARK: - Applier

    func testMultiCaretInsertionRemapsOffsets() {
        let result = MultiCaretApplier.apply(
            insertion("X"),
            to: "0123456789",
            carets: [
                NSRange(location: 1, length: 0),
                NSRange(location: 5, length: 0),
                NSRange(location: 9, length: 0)
            ]
        )

        XCTAssertEqual(result.text, "0X1234X5678X9")
        XCTAssertEqual(result.carets, [
            NSRange(location: 2, length: 0),
            NSRange(location: 7, length: 0),
            NSRange(location: 12, length: 0)
        ])
    }

    func testApplierRunsBottomMostCaretFirst() {
        var visited: [Int] = []
        let transform: MultiCaretApplier.TextTransform = { text, selection in
            visited.append(selection.location)
            return (text, selection)
        }

        let state = MultiCaretState(carets: [
            NSRange(location: 1, length: 0),
            NSRange(location: 5, length: 0),
            NSRange(location: 9, length: 0)
        ])
        let result = MultiCaretApplier.apply(transform, to: "0123456789", state: state)

        XCTAssertEqual(visited, [9, 5, 1])
        XCTAssertEqual(result.text, "0123456789")
        XCTAssertEqual(result.state, state)
    }

    func testDeleteLineAtMultipleCaretsStaysValid() {
        // "one\ntwo\nthree\nfour" — carets on "two" and "four".
        let result = MultiCaretApplier.apply(
            LineOps.deleteLine,
            to: "one\ntwo\nthree\nfour",
            carets: [
                NSRange(location: 4, length: 0),
                NSRange(location: 14, length: 0)
            ]
        )

        XCTAssertEqual(result.text, "one\nthree")
        XCTAssertEqual(result.carets, [
            NSRange(location: 4, length: 0),
            NSRange(location: 9, length: 0)
        ])
    }

    func testOverlappingCaretsCollapseBeforeApplying() {
        // The two selections overlap, so they normalize to 0..<4 and the
        // transform runs exactly once, over the outermost range.
        let state = MultiCaretState(carets: [
            NSRange(location: 0, length: 2),
            NSRange(location: 1, length: 3)
        ])
        XCTAssertEqual(state.carets, [NSRange(location: 0, length: 4)])

        let result = MultiCaretApplier.apply(LineOps.uppercase, to: "abcdef", state: state)

        XCTAssertEqual(result.text, "ABCDef")
        XCTAssertEqual(result.state.carets, [NSRange(location: 0, length: 4)])
    }

    func testEmptyStateLeavesTextUntouched() {
        var calls = 0
        let transform: MultiCaretApplier.TextTransform = { text, selection in
            calls += 1
            return (text, selection)
        }

        let result = MultiCaretApplier.apply(transform, to: "unchanged", carets: [])

        XCTAssertEqual(result.text, "unchanged")
        XCTAssertTrue(result.carets.isEmpty)
        XCTAssertEqual(calls, 0)
    }

    func testSingleCaretMatchesDirectLineOpsCalls() {
        let text = "alpha\nbeta\ngamma\ndelta"
        let cases: [(name: String, transform: MultiCaretApplier.TextTransform, selection: NSRange)] = [
            ("duplicate-line", LineOps.duplicateLine, NSRange(location: 6, length: 0)),
            ("delete-line", LineOps.deleteLine, NSRange(location: 6, length: 0)),
            ("move-line-up", LineOps.moveLineUp, NSRange(location: 6, length: 0)),
            ("move-line-down", LineOps.moveLineDown, NSRange(location: 6, length: 0)),
            ("toggle-line-comment", { text, selection in
                LineOps.toggleLineComment(text, selection: selection)
            }, NSRange(location: 11, length: 0)),
            ("uppercase", LineOps.uppercase, NSRange(location: 0, length: 5)),
            ("lowercase", LineOps.lowercase, NSRange(location: 0, length: 5))
        ]

        for testCase in cases {
            let direct = testCase.transform(text, testCase.selection)
            let multi = MultiCaretApplier.apply(
                testCase.transform,
                to: text,
                carets: [testCase.selection]
            )

            XCTAssertEqual(multi.text, direct.text, testCase.name)
            XCTAssertEqual(multi.carets, [direct.selection], testCase.name)
        }
    }

    func testStateOverloadMatchesCaretArrayOverload() {
        let carets = [
            NSRange(location: 1, length: 0),
            NSRange(location: 5, length: 0),
            NSRange(location: 9, length: 0)
        ]
        let state = MultiCaretState(carets: carets)

        let fromState = MultiCaretApplier.apply(insertion("X"), to: "0123456789", state: state)
        let fromArray = MultiCaretApplier.apply(insertion("X"), to: "0123456789", carets: carets)

        XCTAssertEqual(fromState.text, fromArray.text)
        XCTAssertEqual(fromState.state.carets, fromArray.carets)
    }

    // MARK: - Helpers

    /// A transform that inserts `marker` at the selection location and puts a
    /// caret immediately after it, like typing at each caret.
    private func insertion(_ marker: String) -> MultiCaretApplier.TextTransform {
        let markerLength = (marker as NSString).length
        return { text, selection in
            let document = NSMutableString(string: text)
            let location = max(0, min(selection.location, document.length))
            document.insert(marker, at: location)
            return (document as String,
                    NSRange(location: location + markerLength, length: selection.length))
        }
    }
}
