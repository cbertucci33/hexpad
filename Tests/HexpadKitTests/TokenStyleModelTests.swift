import XCTest
@testable import HexpadKit

/// Coverage for the five-style token model behind Search > Style All
/// Occurrences of Token and its sibling commands.
final class TokenStyleModelTests: XCTestCase {

    private let registry = CommandRegistry.default

    private func makeState(_ text: String,
                           selection: NSRange,
                           styles: TokenStyleState = TokenStyleState()) -> DocumentState {
        DocumentState(text: text, selection: selection, tokenStyleState: styles)
    }

    private func ranges(_ state: TokenStyleState, _ style: Int) -> [NSRange] {
        state.ranges(for: style)
    }

    // MARK: - Styling

    func testStyleAllOccurrencesMatchesWholeWords() {
        let text = "foo bar foo foobar foo"
        let input = makeState(text, selection: NSRange(location: 0, length: 0))

        let result = registry.execute("style-all-occurrences-2", on: input)
        let styles = result?.tokenStyleState

        XCTAssertNotNil(styles)
        // "foobar" must not contribute its leading "foo".
        XCTAssertEqual(styles.map { ranges($0, 2) },
                       [NSRange(location: 0, length: 3),
                        NSRange(location: 8, length: 3),
                        NSRange(location: 19, length: 3)])
        XCTAssertEqual(result?.selection, input.selection)
        XCTAssertEqual(result?.text, text)
    }

    func testStyleAllOccurrencesUsesTheSelectionLiterally() {
        let text = "a + b = c; a + b"
        let input = makeState(text, selection: NSRange(location: 0, length: 5))

        let result = registry.execute("style-all-occurrences-1", on: input)

        XCTAssertEqual(result.map { ranges($0.tokenStyleState, 1) },
                       [NSRange(location: 0, length: 5),
                        NSRange(location: 11, length: 5)])
    }

    func testStyleAllOccurrencesWithNoWordAtCaretIsANoOp() {
        let input = makeState("   ", selection: NSRange(location: 1, length: 0))
        let result = registry.execute("style-all-occurrences-1", on: input)
        XCTAssertEqual(result, input)
    }

    func testStyleOneTokenStylesOnlyTheCurrentRange() {
        let text = "foo bar foo"
        let input = makeState(text, selection: NSRange(location: 8, length: 3))

        let result = registry.execute("style-one-token-3", on: input)

        XCTAssertEqual(result.map { ranges($0.tokenStyleState, 3) },
                       [NSRange(location: 8, length: 3)])
    }

    func testStylingARangeIntoAnotherStyleRemovesTheOverlap() {
        var state = TokenStyleState()
        XCTAssertTrue(state.add(NSRange(location: 4, length: 3), style: 1))
        XCTAssertTrue(state.add(NSRange(location: 4, length: 3), style: 2))

        XCTAssertTrue(state.ranges(for: 1).isEmpty)
        XCTAssertEqual(state.ranges(for: 2), [NSRange(location: 4, length: 3)])
    }

    func testAdjacentRangesInOneStyleMerge() {
        var state = TokenStyleState()
        state.add(NSRange(location: 0, length: 2), style: 1)
        state.add(NSRange(location: 2, length: 2), style: 1)
        XCTAssertEqual(state.ranges(for: 1), [NSRange(location: 0, length: 4)])
    }

    // MARK: - Clearing

    func testClearRemovesOneStyleAndClearAllRemovesEverything() {
        let styles = TokenStyleState(styles: [
            1: [NSRange(location: 0, length: 3)],
            2: [NSRange(location: 4, length: 3)]
        ])
        let input = makeState("foo bar", selection: NSRange(location: 0, length: 0), styles: styles)

        let one = registry.execute("clear-style-1", on: input)?.tokenStyleState
        XCTAssertEqual(one?.ranges(for: 1), [])
        XCTAssertEqual(one?.ranges(for: 2), [NSRange(location: 4, length: 3)])

        let all = registry.execute("clear-style-all", on: input)?.tokenStyleState
        XCTAssertTrue(all?.isEmpty == true)
    }

    func testClearOnAnEmptyStyleIsANoOp() {
        let input = makeState("foo", selection: NSRange(location: 0, length: 0))
        XCTAssertEqual(registry.execute("clear-style-1", on: input), input)
        XCTAssertEqual(registry.execute("clear-style-all", on: input), input)
    }

    // MARK: - Jumping

    private func jumpState() -> DocumentState {
        let styles = TokenStyleState(styles: [
            1: [NSRange(location: 0, length: 3),
                NSRange(location: 8, length: 3),
                NSRange(location: 16, length: 3)]
        ])
        return makeState("abc def abc def abc",
                         selection: NSRange(location: 0, length: 0),
                         styles: styles)
    }

    func testJumpDownWalksStyledRangesInOrderAndWraps() {
        var state = jumpState()
        XCTAssertEqual(registry.execute("jump-down-1", on: state)?.selection,
                       NSRange(location: 8, length: 0))

        state.selection = NSRange(location: 8, length: 0)
        XCTAssertEqual(registry.execute("jump-down-1", on: state)?.selection,
                       NSRange(location: 16, length: 0))

        state.selection = NSRange(location: 16, length: 0)
        XCTAssertEqual(registry.execute("jump-down-1", on: state)?.selection,
                       NSRange(location: 0, length: 0))
    }

    func testJumpUpWalksStyledRangesBackwardsAndWraps() {
        var state = jumpState()
        state.selection = NSRange(location: 16, length: 0)
        XCTAssertEqual(registry.execute("jump-up-1", on: state)?.selection,
                       NSRange(location: 8, length: 0))

        state.selection = NSRange(location: 8, length: 0)
        XCTAssertEqual(registry.execute("jump-up-1", on: state)?.selection,
                       NSRange(location: 0, length: 0))

        state.selection = NSRange(location: 0, length: 0)
        XCTAssertEqual(registry.execute("jump-up-1", on: state)?.selection,
                       NSRange(location: 16, length: 0))
    }

    func testJumpInsideARangeSkipsToTheNeighbouringRange() {
        var state = jumpState()
        state.selection = NSRange(location: 9, length: 0) // inside the middle range

        XCTAssertEqual(registry.execute("jump-down-1", on: state)?.selection,
                       NSRange(location: 16, length: 0))
        XCTAssertEqual(registry.execute("jump-up-1", on: state)?.selection,
                       NSRange(location: 0, length: 0))
    }

    func testJumpWithNoRangesIsANoOp() {
        let input = makeState("abc", selection: NSRange(location: 0, length: 0))
        XCTAssertEqual(registry.execute("jump-up-1", on: input), input)
        XCTAssertEqual(registry.execute("jump-down-1", on: input), input)
    }

    // MARK: - Copying

    func testCopyStyledTextCopiesOneStyleInDocumentOrder() {
        let styles = TokenStyleState(styles: [
            1: [NSRange(location: 0, length: 3),
                NSRange(location: 8, length: 3)],
            2: [NSRange(location: 4, length: 3)]
        ])
        let input = makeState("foo bar baz", selection: NSRange(location: 0, length: 0), styles: styles)

        let output = registry.execute("copy-styled-text-1", on: input, clipboard: nil)
        XCTAssertEqual(output?.clipboard, "foo\nbaz")
        XCTAssertEqual(output?.state, input)

        let all = registry.execute("copy-styled-text-all", on: input, clipboard: nil)
        XCTAssertEqual(all?.clipboard, "foo\nbar\nbaz")
    }

    func testCopyStyledTextWithNoRangesLeavesTheClipboardAlone() {
        let input = makeState("foo", selection: NSRange(location: 0, length: 0))
        XCTAssertNil(registry.execute("copy-styled-text-1", on: input, clipboard: "keep")?.clipboard)
        XCTAssertNil(registry.execute("copy-styled-text-all", on: input, clipboard: "keep")?.clipboard)
    }

    // MARK: - Edit remapping

    func testInsertionBeforeARangeShiftsIt() {
        let state = TokenStyleState(styles: [1: [NSRange(location: 4, length: 3)]])
        let edit = FoldTextEdit(location: 0, replacedLength: 0, insertedLength: 2)

        let remapped = state.remapped(from: "foo bar", for: edit, to: "xxfoo bar")

        XCTAssertEqual(remapped.ranges(for: 1), [NSRange(location: 6, length: 3)])
    }

    func testInsertionInsideARangeExtendsIt() {
        let state = TokenStyleState(styles: [1: [NSRange(location: 0, length: 3)]])
        let edit = FoldTextEdit(location: 1, replacedLength: 0, insertedLength: 1)

        let remapped = state.remapped(from: "foo", for: edit, to: "fXoo")

        XCTAssertEqual(remapped.ranges(for: 1), [NSRange(location: 0, length: 4)])
    }

    func testInsertionAtTheRangeStartShiftsRatherThanExtends() {
        let state = TokenStyleState(styles: [1: [NSRange(location: 4, length: 3)]])
        let edit = FoldTextEdit(location: 4, replacedLength: 0, insertedLength: 1)

        let remapped = state.remapped(from: "foo bar", for: edit, to: "foo Xbar")

        XCTAssertEqual(remapped.ranges(for: 1), [NSRange(location: 5, length: 3)])
    }

    func testDeletionInsideARangeShrinksIt() {
        let state = TokenStyleState(styles: [1: [NSRange(location: 4, length: 3)]])
        let edit = FoldTextEdit(location: 5, replacedLength: 1, insertedLength: 0)

        let remapped = state.remapped(from: "foo bar", for: edit, to: "foo br")

        XCTAssertEqual(remapped.ranges(for: 1), [NSRange(location: 4, length: 2)])
    }

    func testDeletionCoveringTheWholeRangeDropsIt() {
        let state = TokenStyleState(styles: [
            1: [NSRange(location: 4, length: 3)],
            2: [NSRange(location: 0, length: 3)]
        ])
        let edit = FoldTextEdit(location: 4, replacedLength: 3, insertedLength: 0)

        let remapped = state.remapped(from: "foo bar", for: edit, to: "foo ")

        XCTAssertTrue(remapped.ranges(for: 1).isEmpty)
        XCTAssertEqual(remapped.ranges(for: 2), [NSRange(location: 0, length: 3)])
    }

    func testRemapThroughTheModelAdoptsTheNewText() {
        let model = TokenStyleModel(
            text: "foo bar",
            tokenStyleState: TokenStyleState(styles: [1: [NSRange(location: 4, length: 3)]])
        )
        var updated = model
        updated.remap(for: FoldTextEdit(location: 0, replacedLength: 0, insertedLength: 2),
                      in: "xxfoo bar")

        XCTAssertEqual(updated.text, "xxfoo bar")
        XCTAssertEqual(updated.ranges(for: 1), [NSRange(location: 6, length: 3)])
    }

    func testRevalidationClipsRangesToShorterText() {
        let state = TokenStyleState(styles: [
            1: [NSRange(location: 0, length: 3),
                NSRange(location: 10, length: 3)]
        ])

        let revalidated = state.revalidated(in: "foo bar")

        XCTAssertEqual(revalidated.ranges(for: 1), [NSRange(location: 0, length: 3)])
    }

    // MARK: - Registry surface

    func testRegistryExposesEveryTokenStyleCommand() {
        let expected = ["style-all-occurrences", "style-one-token",
                        "clear-style", "jump-up", "jump-down",
                        "copy-styled-text"]
        for prefix in expected {
            let styleCount = registry.tokenStyleCommands.filter {
                $0.identifier.hasPrefix("\(prefix)-") && Int($0.identifier.dropFirst(prefix.count + 1)) != nil
            }.count
            XCTAssertEqual(styleCount, 5, prefix)
        }
        XCTAssertEqual(registry.tokenStyleCommands.count, 32)
        XCTAssertNotNil(registry.command(for: "clear-style-all"))
        XCTAssertNotNil(registry.command(for: "copy-styled-text-all"))
    }

    // MARK: - Session persistence

    func testTokenStylesRoundTripThroughEditorStateSessionData() throws {
        let styles = TokenStyleState(styles: [
            1: [NSRange(location: 0, length: 3)],
            4: [NSRange(location: 8, length: 3),
                NSRange(location: 14, length: 2)]
        ])
        let editorState = DocumentEditorState(tokenStyleState: styles)

        let data = editorState.toSessionData()
        let restored = DocumentEditorState.fromSessionData(data)

        XCTAssertEqual(restored.tokenStyleState, styles)
        XCTAssertEqual(restored, editorState)
    }

    func testTokenStylesSurviveJSONSerialization() throws {
        let styles = TokenStyleState(styles: [3: [NSRange(location: 2, length: 4)]])
        let data = DocumentEditorState(tokenStyleState: styles).toSessionData()

        let encoded = try JSONSerialization.data(withJSONObject: data)
        let decoded = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        let restored = DocumentEditorState.fromSessionData(decoded)

        XCTAssertEqual(restored.tokenStyleState, styles)
    }

    func testMalformedSessionDataRestoresEmptyStyles() {
        XCTAssertTrue(TokenStyleState.fromSessionData(nil).isEmpty)
        XCTAssertTrue(TokenStyleState.fromSessionData([:]).isEmpty)
        XCTAssertTrue(TokenStyleState.fromSessionData(["styles": "nope"]).isEmpty)
        XCTAssertTrue(TokenStyleState.fromSessionData([
            "styles": ["9": [[0, 3]], "1": [[0]]]
        ]).isEmpty)
    }

    // MARK: - Palette

    func testPaletteProvidesFiveDistinctThemeAwareColours() {
        for theme in [HexpadTheme.light.theme, HexpadTheme.dark.theme] {
            let colors = TokenStylePalette.colors(for: theme)
            XCTAssertEqual(colors.count, 5)
            for (index, color) in colors.enumerated() {
                let rgb = color.usingColorSpace(.deviceRGB)
                XCTAssertNotNil(rgb, "style \(index + 1)")
                XCTAssertEqual(rgb?.alphaComponent ?? 0, theme.name == "Dark" ? 0.30 : 0.22,
                               accuracy: 0.001)
                if index > 0 {
                    let previous = colors[index - 1].usingColorSpace(.deviceRGB)
                    XCTAssertNotEqual(rgb?.hueComponent, previous?.hueComponent)
                }
            }
        }
    }
}
