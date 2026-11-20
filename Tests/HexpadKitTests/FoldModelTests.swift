import XCTest
@testable import HexpadKit

final class FoldModelTests: XCTestCase {

    // MARK: - Fixtures

    /// A fixture with every metadata category the fold model consumes.
    private var richDefinition: LexerDefinition {
        LexerDefinition(
            language: "Fixture",
            rules: [],
            comments: LexerDefinition.CommentSyntax(
                linePrefix: "//",
                blockStart: "/*",
                blockEnd: "*/"
            ),
            brackets: [
                LexerDefinition.BracketPair(open: "{", close: "}"),
                LexerDefinition.BracketPair(open: "(", close: ")"),
                LexerDefinition.BracketPair(open: "[", close: "]")
            ]
        )
    }

    private func definition(
        comments: LexerDefinition.CommentSyntax? = nil,
        brackets: [LexerDefinition.BracketPair] = []
    ) -> LexerDefinition {
        LexerDefinition(language: "Fixture", rules: [], comments: comments, brackets: brackets)
    }

    private var allBrackets: [LexerDefinition.BracketPair] {
        richDefinition.brackets
    }

    private func offset(of needle: String, in text: String, from start: Int = 0) -> Int {
        let nsText = text as NSString
        let range = NSRange(location: start, length: nsText.length - start)
        let found = nsText.range(of: needle, options: [], range: range)
        XCTAssertNotEqual(found.location, NSNotFound, "missing \(needle) in fixture")
        return found.location
    }

    private func lastOffset(of needle: String, in text: String) -> Int {
        let nsText = text as NSString
        let found = nsText.range(of: needle,
                                 options: .backwards,
                                 range: NSRange(location: 0, length: nsText.length))
        XCTAssertNotEqual(found.location, NSNotFound, "missing \(needle) in fixture")
        return found.location
    }

    private func fold(open: String,
                      close: String,
                      in text: String,
                      kind: FoldRange.Kind = .braces) -> FoldRange {
        let start = offset(of: open, in: text)
        let closeStart = offset(of: close, in: text, from: start + open.utf16.count)
        return FoldRange(location: start,
                         length: closeStart + close.utf16.count - start,
                         kind: kind)
    }

    private func newlineOffset(in text: String, from start: Int) -> Int {
        offset(of: "\n", in: text, from: start)
    }

    // MARK: - Nesting

    func testBraceFoldsNestInsideOneAnother() {
        let text = """
        func outer() {
            if (inner) {
                work()
            }
        }
        """
        let model = FoldModel(text: text, definition: definition(brackets: allBrackets))

        let outerOpen = offset(of: "{", in: text)
        let outerClose = lastOffset(of: "}", in: text)
        let innerOpen = offset(of: "{", in: text, from: outerOpen + 1)
        let innerClose = offset(of: "}", in: text, from: innerOpen + 1)

        XCTAssertEqual(model.foldableRanges.count, 2)
        XCTAssertEqual(model.foldableRanges[0].range,
                       NSRange(location: outerOpen, length: outerClose + 1 - outerOpen))
        XCTAssertEqual(model.foldableRanges[1].range,
                       NSRange(location: innerOpen, length: innerClose + 1 - innerOpen))
        XCTAssertEqual(model.foldableRanges.map(\.kind), [.braces, .braces])
        XCTAssertTrue(NSLocationInRange(innerOpen, model.foldableRanges[0].range))
        XCTAssertTrue(NSLocationInRange(innerClose, model.foldableRanges[0].range))
    }

    func testNestedFoldsComputeVisibilityFromTheOutermostCollapsedRange() {
        let text = """
        func outer() {
            if (inner) {
                work()
            }
        }
        """
        var model = FoldModel(text: text, definition: definition(brackets: allBrackets))
        let outer = model.foldableRanges[0]
        let inner = model.foldableRanges[1]

        XCTAssertTrue(model.fold(inner))
        var visibility = model.visibility()
        let innerNewline = newlineOffset(in: text, from: inner.location)
        XCTAssertEqual(visibility.hiddenRanges, [
            NSRange(location: innerNewline, length: inner.upperBound - innerNewline)
        ])
        XCTAssertTrue(visibility.isVisible(inner.location))

        XCTAssertTrue(model.fold(outer))
        visibility = model.visibility()
        let outerNewline = newlineOffset(in: text, from: outer.location)
        XCTAssertEqual(visibility.hiddenRanges, [
            NSRange(location: outerNewline, length: outer.upperBound - outerNewline)
        ])
        XCTAssertFalse(visibility.isVisible(inner.location))
    }

    // MARK: - Fold / unfold / toggle

    func testFoldUnfoldAndToggle() {
        let text = "head {\n  body\n}\ntail"
        var model = FoldModel(text: text, definition: definition(brackets: allBrackets))
        let braceFold = fold(open: "{", close: "}", in: text)

        XCTAssertEqual(model.foldableRanges, [braceFold])
        XCTAssertFalse(model.isCollapsed(braceFold))

        XCTAssertTrue(model.fold(braceFold))
        XCTAssertTrue(model.isCollapsed(braceFold))
        XCTAssertEqual(model.collapsedRanges, [braceFold])
        XCTAssertFalse(model.fold(braceFold), "already collapsed")

        XCTAssertTrue(model.unfold(braceFold))
        XCTAssertTrue(model.collapsedRanges.isEmpty)
        XCTAssertFalse(model.unfold(braceFold), "already expanded")

        XCTAssertTrue(model.toggle(braceFold))
        XCTAssertTrue(model.isCollapsed(braceFold))
        XCTAssertTrue(model.toggle(braceFold))
        XCTAssertFalse(model.isCollapsed(braceFold))
    }

    func testFoldRejectsRangesThatAreNotFoldable() {
        let text = "head {\n  body\n}\ntail"
        var model = FoldModel(text: text, definition: definition(brackets: allBrackets))
        let bogus = FoldRange(location: 0, length: 1, kind: .braces)

        XCTAssertFalse(model.fold(bogus))
        XCTAssertFalse(model.toggle(bogus))
        XCTAssertTrue(model.collapsedRanges.isEmpty)
    }

    func testToggleFoldAtLine() {
        let text = "head {\n  body\n}\ntail"
        var model = FoldModel(text: text, definition: definition(brackets: allBrackets))
        let braceFold = fold(open: "{", close: "}", in: text)

        XCTAssertEqual(model.foldableRange(startingAtLine: 1), braceFold)
        XCTAssertNil(model.foldableRange(startingAtLine: 2))
        XCTAssertNil(model.foldableRange(startingAtLine: 3))

        XCTAssertTrue(model.toggleFold(atLine: 1))
        XCTAssertTrue(model.isCollapsed(braceFold))
        XCTAssertTrue(model.toggleFold(atLine: 1))
        XCTAssertFalse(model.isCollapsed(braceFold))
        XCTAssertFalse(model.toggleFold(atLine: 2), "no fold starts on the body line")
    }

    func testFoldAllAndUnfoldAll() {
        let text = """
        if a {
            x
        }
        if b {
            y
        }
        """
        var model = FoldModel(text: text, definition: definition(brackets: allBrackets))

        XCTAssertEqual(model.foldableRanges.count, 2)
        XCTAssertEqual(model.foldAll(), 2)
        XCTAssertEqual(model.collapsedRanges.count, 2)
        XCTAssertTrue(model.foldableRanges.allSatisfy { model.isCollapsed($0) })

        XCTAssertEqual(model.foldAll(), 0, "nothing new to fold")
        XCTAssertEqual(model.unfoldAll(), 2)
        XCTAssertTrue(model.collapsedRanges.isEmpty)
        XCTAssertEqual(model.unfoldAll(), 0)
    }

    // MARK: - Fold levels

    /// A Python-style fixture: three brace-delimited blocks nested one inside
    /// the next, so their depths are exactly 1, 2 and 3.
    private var nestedText: String {
        """
        function outer() {
            function inner() {
                if (flag) {
                    work();
                }
                return 1;
            }
            return 2;
        }
        """
    }

    func testFoldDepthsFollowContainment() {
        let model = FoldModel(text: nestedText, definition: definition(brackets: allBrackets))

        XCTAssertEqual(model.foldableRanges.count, 3)
        XCTAssertEqual(model.foldableRanges.map { model.depth(of: $0) }, [1, 2, 3])
        XCTAssertEqual(model.foldableRanges(atDepth: 1), [model.foldableRanges[0]])
        XCTAssertEqual(model.foldableRanges(atDepth: 2), [model.foldableRanges[1]])
        XCTAssertEqual(model.foldableRanges(atDepth: 3), [model.foldableRanges[2]])
        XCTAssertTrue(model.foldableRanges(atDepth: 4).isEmpty)
        XCTAssertTrue(model.foldableRanges(atDepth: 0).isEmpty)
    }

    func testDeeplyNestedFoldsComputeDepthInOnePass() {
        // A thousand nested braces: the depth pass must produce 1...N in model
        // order. The old O(folds²) pairwise containment count did ~1M
        // comparisons here; correctness is the point, but a non-linear
        // implementation would also make this visibly slow.
        let depth = 1_000
        let text = String(repeating: "{\n", count: depth)
            + String(repeating: "}\n", count: depth)
        let model = FoldModel(text: text, definition: definition(brackets: allBrackets))

        XCTAssertEqual(model.foldableRanges.count, depth)
        XCTAssertEqual(model.foldableRanges.map { model.depth(of: $0) },
                       Array(1...depth))
    }

    func testFoldStartLinesAreComputedInOnePass() {
        let text = "a {\n    b {\n        c\n    }\n}\nd {\n}\n"
        let model = FoldModel(text: text, definition: definition(brackets: allBrackets))

        XCTAssertEqual(model.foldableRanges.count, 3)
        // Fold starts land on lines 1 (outer), 2 (inner), 6 (sibling).
        XCTAssertEqual(model.foldableRanges.map { model.startingLine(of: $0) },
                       [1, 2, 6])
        // The precomputed mapping must agree with the direct line math it
        // replaces, for every fold.
        for fold in model.foldableRanges {
            XCTAssertEqual(model.startingLine(of: fold),
                           GutterGeometry.logicalLine(of: fold.location, in: text))
        }
    }

    func testFoldDepthsHandleBraceRegionPartialOverlap() {
        // A brace fold and a region fold can partially overlap: the brace opens
        // before the region and closes inside it. Neither strictly contains the
        // other, so both stay depth 1 (matching the old pairwise semantics).
        let text = "{\n// region start\nx\n}\n// endregion\n"
        let configuration = FoldConfiguration(regionMarkers: [
            FoldRegionMarker(start: "// region", end: "// endregion")
        ])
        let model = FoldModel(text: text,
                              definition: definition(
                                  comments: LexerDefinition.CommentSyntax(linePrefix: "//"),
                                  brackets: allBrackets),
                              configuration: configuration)

        XCTAssertEqual(model.foldableRanges.count, 2)
        XCTAssertEqual(model.foldableRanges.map(\.kind), [.braces, .region])
        XCTAssertEqual(model.foldableRanges.map { model.depth(of: $0) }, [1, 1])
    }

    func testFoldCurrentLevelTargetsTheInnermostRangeContainingTheCaretLine() {
        let text = nestedText
        var model = FoldModel(text: text, definition: definition(brackets: allBrackets))
        let outer = model.foldableRanges[0]
        let inner = model.foldableRanges[1]
        let ifBody = model.foldableRanges[2]

        // Caret on the "function inner():" line is inside both the outer and inner
        // blocks; the innermost (depth 2) wins.
        let innerLine = offset(of: "function inner", in: text)
        XCTAssertEqual(model.innermostFoldableRange(containing: NSRange(location: innerLine, length: 0)),
                       inner)
        XCTAssertTrue(model.foldCurrentLevel(selection: NSRange(location: innerLine, length: 0)))
        XCTAssertEqual(model.collapsedRanges, [inner])

        // Unfold is the exact inverse and leaves the other levels alone.
        XCTAssertTrue(model.unfoldCurrentLevel(selection: NSRange(location: innerLine, length: 0)))
        XCTAssertTrue(model.collapsedRanges.isEmpty)
        XCTAssertFalse(model.unfoldCurrentLevel(selection: NSRange(location: innerLine, length: 0)),
                       "already expanded")

        // Caret on the "if (flag):" line reaches depth 3.
        let flagLine = offset(of: "if (flag)", in: text)
        XCTAssertTrue(model.foldCurrentLevel(selection: NSRange(location: flagLine, length: 0)))
        XCTAssertEqual(model.collapsedRanges, [ifBody])

        // Caret on the outer header line reaches only depth 1.
        let outerLine = offset(of: "function outer", in: text)
        XCTAssertTrue(model.foldCurrentLevel(selection: NSRange(location: outerLine, length: 0)))
        XCTAssertEqual(model.collapsedRanges, [ifBody, outer])
    }

    func testFoldCurrentLevelWithoutAFoldableRangeIsANoOp() {
        var model = FoldModel(text: "plain\ntext", definition: definition(brackets: allBrackets))
        XCTAssertNil(model.innermostFoldableRange(containing: NSRange(location: 0, length: 0)))
        XCTAssertFalse(model.foldCurrentLevel(selection: NSRange(location: 0, length: 0)))
        XCTAssertFalse(model.unfoldCurrentLevel(selection: NSRange(location: 0, length: 0)))
        XCTAssertTrue(model.collapsedRanges.isEmpty)
    }

    func testFoldAndUnfoldLevelOnlyTouchTheirDepth() {
        var model = FoldModel(text: nestedText, definition: definition(brackets: allBrackets))
        let outer = model.foldableRanges[0]
        let inner = model.foldableRanges[1]
        let ifBody = model.foldableRanges[2]

        XCTAssertEqual(model.foldLevel(2), 1)
        XCTAssertEqual(model.collapsedRanges, [inner])
        XCTAssertEqual(model.foldLevel(2), 0, "already collapsed")

        XCTAssertEqual(model.foldLevel(1), 1)
        XCTAssertEqual(model.foldLevel(3), 1)
        XCTAssertEqual(model.collapsedRanges, [outer, inner, ifBody])

        XCTAssertEqual(model.unfoldLevel(2), 1)
        XCTAssertEqual(model.collapsedRanges, [outer, ifBody])
        XCTAssertEqual(model.unfoldLevel(2), 0)
        XCTAssertEqual(model.unfoldLevel(1), 1)
        XCTAssertEqual(model.unfoldLevel(3), 1)
        XCTAssertTrue(model.collapsedRanges.isEmpty)

        // Out-of-range depths are no-ops rather than traps.
        XCTAssertEqual(model.foldLevel(0), 0)
        XCTAssertEqual(model.foldLevel(9), 0)
        XCTAssertEqual(model.unfoldLevel(0), 0)
        XCTAssertEqual(model.unfoldLevel(9), 0)
    }

    // MARK: - Visibility

    func testVisibilityMappingForOneFold() {
        let text = "a {\n    b\n}\nc"
        var model = FoldModel(text: text, definition: definition(brackets: allBrackets))
        let braceFold = fold(open: "{", close: "}", in: text)
        XCTAssertTrue(model.fold(braceFold))

        let visibility = model.visibility()
        XCTAssertEqual(visibility.documentLength, text.utf16.count)
        XCTAssertEqual(visibility.visibleRanges, [
            NSRange(location: 0, length: 3),
            NSRange(location: 11, length: 2)
        ])
        XCTAssertEqual(visibility.hiddenRanges, [NSRange(location: 3, length: 8)])
        XCTAssertEqual(visibility.visibleLength, 5)
        XCTAssertEqual(model.visibleRanges, visibility.visibleRanges)

        // Opening line remains visible; the newline and body are hidden.
        XCTAssertEqual(visibility.visiblePosition(ofDocumentPosition: 0), 0)
        XCTAssertEqual(visibility.visiblePosition(ofDocumentPosition: 2), 2)
        XCTAssertEqual(visibility.visiblePosition(ofDocumentPosition: 3), 3)
        XCTAssertEqual(visibility.visiblePosition(ofDocumentPosition: 8), 3)
        XCTAssertEqual(visibility.visiblePosition(ofDocumentPosition: 10), 3)
        XCTAssertEqual(visibility.visiblePosition(ofDocumentPosition: 11), 3)
        XCTAssertEqual(visibility.visiblePosition(ofDocumentPosition: 12), 4)
        XCTAssertEqual(visibility.visiblePosition(ofDocumentPosition: 13), 5)
        XCTAssertEqual(model.visiblePosition(of: 12), 4)

        XCTAssertTrue(visibility.isVisible(2))
        XCTAssertFalse(visibility.isVisible(3))
        XCTAssertFalse(visibility.isVisible(8))
        XCTAssertTrue(visibility.isVisible(11))
        XCTAssertTrue(visibility.isVisible(12))

        XCTAssertEqual(visibility.documentPosition(ofVisiblePosition: 3), 3)
        XCTAssertEqual(visibility.documentPosition(ofVisiblePosition: 4), 12)
        XCTAssertEqual(visibility.documentPosition(ofVisiblePosition: 5), 13)
    }

    func testVisibilityMappingAccountsForEarlierFolds() {
        let text = "a {\n  b\n}\nc {\n  d\n}\n"
        var model = FoldModel(text: text, definition: definition(brackets: allBrackets))
        XCTAssertEqual(model.foldableRanges.count, 2)
        XCTAssertEqual(model.foldAll(), 2)

        let visibility = model.visibility()
        XCTAssertEqual(visibility.visibleRanges, [
            NSRange(location: 0, length: 3),
            NSRange(location: 9, length: 4),
            NSRange(location: 19, length: 1)
        ])
        XCTAssertEqual(visibility.hiddenRanges, [
            NSRange(location: 3, length: 6),
            NSRange(location: 13, length: 6)
        ])
        XCTAssertEqual(visibility.visibleLength, 8)

        XCTAssertEqual(visibility.visiblePosition(ofDocumentPosition: 9), 3)
        XCTAssertEqual(visibility.visiblePosition(ofDocumentPosition: 12), 6)
        XCTAssertEqual(visibility.visiblePosition(ofDocumentPosition: 13), 7)
        XCTAssertEqual(visibility.visiblePosition(ofDocumentPosition: 19), 7)
        XCTAssertEqual(visibility.visiblePosition(ofDocumentPosition: 20), 8)
    }

    func testFoldsContainingOnlyOneLineHideWholeConstruct() {
        let text = "call(a, b)"
        let model = FoldModel(
            text: text,
            definition: definition(brackets: allBrackets),
            configuration: FoldConfiguration(foldsSingleLineRanges: true)
        )
        var mutable = model
        let parenFold = fold(open: "(", close: ")", in: text, kind: .parentheses)
        XCTAssertEqual(model.foldableRanges, [parenFold])
        XCTAssertTrue(mutable.fold(parenFold))

        let visibility = mutable.visibility()
        XCTAssertEqual(visibility.visibleRanges, [NSRange(location: 0, length: 4)])
        XCTAssertEqual(visibility.hiddenRanges, [NSRange(location: 4, length: 6)])
        XCTAssertEqual(visibility.visibleLength, 4)
    }

    // MARK: - Edit remapping

    func testRemapInsertionBeforeFoldShiftsIt() {
        let original = FoldState(collapsedRanges: [
            FoldRange(location: 10, length: 10, kind: .braces)
        ])
        let remapped = original.remapped(for: .insertion(at: 5, length: 3))

        XCTAssertEqual(remapped.collapsedRanges, [
            FoldRange(location: 13, length: 10, kind: .braces)
        ])
        XCTAssertEqual(original.collapsedRanges, [
            FoldRange(location: 10, length: 10, kind: .braces)
        ], "remapping must be pure")
    }

    func testRemapInsertionAtFoldStartShiftsIt() {
        XCTAssertEqual(
            FoldState.remappedRange(NSRange(location: 10, length: 10),
                                    for: .insertion(at: 10, length: 2)),
            NSRange(location: 12, length: 10)
        )
    }

    func testRemapInsertionInsideFoldExpandsIt() {
        XCTAssertEqual(
            FoldState.remappedRange(NSRange(location: 10, length: 10),
                                    for: .insertion(at: 12, length: 4)),
            NSRange(location: 10, length: 14)
        )
    }

    func testRemapInsertionAtEndOrAfterFoldLeavesItUnchanged() {
        XCTAssertEqual(
            FoldState.remappedRange(NSRange(location: 10, length: 10),
                                    for: .insertion(at: 20, length: 5)),
            NSRange(location: 10, length: 10)
        )
        XCTAssertEqual(
            FoldState.remappedRange(NSRange(location: 10, length: 10),
                                    for: .insertion(at: 25, length: 5)),
            NSRange(location: 10, length: 10)
        )
    }

    func testRemapDeletionBeforeAndAfterFold() {
        XCTAssertEqual(
            FoldState.remappedRange(NSRange(location: 10, length: 10),
                                    for: .deletion(NSRange(location: 2, length: 4))),
            NSRange(location: 6, length: 10)
        )
        XCTAssertEqual(
            FoldState.remappedRange(NSRange(location: 10, length: 10),
                                    for: .deletion(NSRange(location: 22, length: 2))),
            NSRange(location: 10, length: 10)
        )
    }

    func testRemapDeletionInsideFoldShrinksIt() {
        XCTAssertEqual(
            FoldState.remappedRange(NSRange(location: 10, length: 10),
                                    for: .deletion(NSRange(location: 12, length: 3))),
            NSRange(location: 10, length: 7)
        )
    }

    func testRemapDeletionSpanningFoldDropsItAndShiftsLaterFolds() {
        let first = FoldRange(location: 10, length: 10, kind: .braces)
        let second = FoldRange(location: 30, length: 10, kind: .brackets)
        let state = FoldState(collapsedRanges: [first, second])

        let remapped = state.remapped(for: .deletion(NSRange(location: 5, length: 10)))

        XCTAssertEqual(remapped.collapsedRanges, [
            FoldRange(location: 20, length: 10, kind: .brackets)
        ])
        XCTAssertEqual(state.collapsedRanges.count, 2)
    }

    func testRemapDeletionCoveringWholeFoldDropsIt() {
        let state = FoldState(collapsedRanges: [
            FoldRange(location: 10, length: 10, kind: .braces)
        ])
        XCTAssertTrue(state.remapped(for: .deletion(NSRange(location: 10, length: 10))).isEmpty)
        XCTAssertTrue(state.remapped(for: .deletion(NSRange(location: 8, length: 14))).isEmpty)
        XCTAssertTrue(state.remapped(for: .deletion(NSRange(location: 10, length: 1))).isEmpty)
        XCTAssertTrue(state.remapped(for: .deletion(NSRange(location: 19, length: 1))).isEmpty)
    }

    func testRemapReplacementInsideFoldAdjustsLength() {
        XCTAssertEqual(
            FoldState.remappedRange(NSRange(location: 10, length: 10),
                                    for: FoldTextEdit(location: 12,
                                                      replacedLength: 3,
                                                      insertedLength: 7)),
            NSRange(location: 10, length: 14)
        )
        XCTAssertEqual(
            FoldState.remappedRange(NSRange(location: 10, length: 10),
                                    for: FoldTextEdit(location: 12,
                                                      replacedLength: 3,
                                                      insertedLength: 1)),
            NSRange(location: 10, length: 8)
        )
    }

    // MARK: - Brace languages

    func testBraceLanguageFixtureMakesSquareBracketsOptIn() {
        let text = """
        {
          "items": [
            1,
            2
          ]
        }
        """
        let braceDefinition = definition(brackets: [
            LexerDefinition.BracketPair(open: "{", close: "}"),
            LexerDefinition.BracketPair(open: "[", close: "]")
        ])

        let withoutSquare = FoldModel(text: text, definition: braceDefinition)
        XCTAssertEqual(withoutSquare.foldableRanges.count, 1)
        XCTAssertEqual(withoutSquare.foldableRanges[0].kind, .braces)

        let withSquare = FoldModel(
            text: text,
            definition: braceDefinition,
            configuration: FoldConfiguration(foldsSquareBrackets: true)
        )
        XCTAssertEqual(withSquare.foldableRanges.count, 2)
        XCTAssertEqual(withSquare.foldableRanges.map(\.kind), [.braces, .brackets])
        XCTAssertTrue(NSLocationInRange(withSquare.foldableRanges[1].location,
                                        withSquare.foldableRanges[0].range))
    }

    func testParenthesesAreFoldableWhenDeclared() {
        let text = """
        call(
            one,
            two
        )
        """
        let parenDefinition = definition(brackets: [
            LexerDefinition.BracketPair(open: "(", close: ")")
        ])
        let model = FoldModel(text: text, definition: parenDefinition)

        XCTAssertEqual(model.foldableRanges.count, 1)
        XCTAssertEqual(model.foldableRanges[0].kind, .parentheses)
        XCTAssertEqual(model.foldableRanges[0], fold(open: "(",
                                                     close: ")",
                                                     in: text,
                                                     kind: .parentheses))
    }

    func testSingleLineRangesAreNotFoldableByDefault() {
        let text = "call(a, b)"
        let model = FoldModel(text: text, definition: definition(brackets: allBrackets))
        XCTAssertTrue(model.foldableRanges.isEmpty)
    }

    // MARK: - Block comments

    func testBlockCommentFixtureFoldsAndExcludesDelimitersInsideComments() {
        let text = """
        before
        /* block {
           inner [ text
           close } */
        // line { comment
        after
        """
        let comments = LexerDefinition.CommentSyntax(
            linePrefix: "//",
            blockStart: "/*",
            blockEnd: "*/"
        )
        let model = FoldModel(text: text,
                              definition: definition(comments: comments, brackets: allBrackets))

        let blockStart = offset(of: "/*", in: text)
        let blockEnd = offset(of: "*/", in: text)
        XCTAssertEqual(model.foldableRanges.count, 1)
        XCTAssertEqual(model.foldableRanges[0].kind, .blockComment)
        XCTAssertEqual(model.foldableRanges[0].range,
                       NSRange(location: blockStart, length: blockEnd + 2 - blockStart))
    }

    func testCollapsedBlockCommentHidesItsInterior() {
        let text = """
        before
        /* block {
           inner [ text
           close } */
        after
        """
        let comments = LexerDefinition.CommentSyntax(
            linePrefix: "//",
            blockStart: "/*",
            blockEnd: "*/"
        )
        var model = FoldModel(text: text,
                              definition: definition(comments: comments, brackets: allBrackets))
        let commentFold = model.foldableRanges[0]
        XCTAssertTrue(model.fold(commentFold))

        let visibility = model.visibility()
        let interior = offset(of: "inner", in: text)
        XCTAssertFalse(visibility.isVisible(interior))
        XCTAssertTrue(visibility.isVisible(commentFold.location))
        XCTAssertEqual(visibility.visibleLength,
                       text.utf16.count - (commentFold.upperBound - newlineOffset(in: text,
                                                                                  from: commentFold.location)))
    }

    func testUnterminatedBlockCommentIsNotFoldable() {
        let text = "/* unterminated\n{\n"
        let comments = LexerDefinition.CommentSyntax(
            linePrefix: "//",
            blockStart: "/*",
            blockEnd: "*/"
        )
        let model = FoldModel(text: text,
                              definition: definition(comments: comments, brackets: allBrackets))
        XCTAssertTrue(model.foldableRanges.isEmpty)
    }

    // MARK: - Region markers

    func testRegionMarkersNest() {
        let text = """
        before
        // region outer
          one
          // region inner
          two
          // endregion
        // endregion
        after
        """
        let regionDefinition = definition(
            comments: LexerDefinition.CommentSyntax(linePrefix: "//")
        )
        let configuration = FoldConfiguration(regionMarkers: [
            FoldRegionMarker(start: "// region", end: "// endregion")
        ])
        let model = FoldModel(text: text,
                              definition: regionDefinition,
                              configuration: configuration)

        XCTAssertEqual(model.foldableRanges.count, 2)
        XCTAssertEqual(model.foldableRanges.map(\.kind), [.region, .region])

        let outerStart = offset(of: "// region outer", in: text)
        let innerStart = offset(of: "  // region inner", in: text)
        let innerEnd = offset(of: "// endregion", in: text)
            + "// endregion".utf16.count
        let outerEnd = lastOffset(of: "// endregion", in: text)
            + "// endregion".utf16.count

        let outer = model.foldableRanges[0]
        let inner = model.foldableRanges[1]
        XCTAssertEqual(outer.range, NSRange(location: outerStart,
                                            length: outerEnd - outerStart))
        XCTAssertEqual(inner.range, NSRange(location: innerStart,
                                            length: innerEnd - innerStart))
        XCTAssertTrue(NSLocationInRange(inner.location, outer.range))

        var mutable = model
        XCTAssertTrue(mutable.toggleFold(atLine: 2))
        XCTAssertTrue(mutable.isCollapsed(outer))
        XCTAssertFalse(mutable.isCollapsed(inner))
    }

    func testUnmatchedRegionMarkersProduceNoFolds() {
        let text = "// endregion\n// region open\nbody\n"
        let configuration = FoldConfiguration(regionMarkers: [
            FoldRegionMarker(start: "// region", end: "// endregion")
        ])
        let model = FoldModel(text: text,
                              definition: definition(comments: LexerDefinition.CommentSyntax(linePrefix: "//")),
                              configuration: configuration)
        XCTAssertTrue(model.foldableRanges.isEmpty)
    }

    // MARK: - Re-tokenization and metadata gaps

    func testRecomputationPreservesFoldState() {
        let text = "head {\n  body\n}\ntail"
        var model = FoldModel(text: text, definition: richDefinition)
        let braceFold = model.foldableRanges[0]
        XCTAssertTrue(model.fold(braceFold))

        let recomputed = model.recomputed()
        XCTAssertEqual(recomputed.foldableRanges, model.foldableRanges)
        XCTAssertEqual(recomputed.foldState, model.foldState)
        XCTAssertTrue(recomputed.isCollapsed(braceFold))

        let rebuilt = FoldModel(text: text,
                                definition: richDefinition,
                                foldState: model.foldState)
        XCTAssertTrue(rebuilt.isCollapsed(braceFold))
    }

    func testDefinitionWithoutMetadataProducesNoFolds() {
        let text = """
        /* not a comment in this grammar */
        func f() {
            body()
        }
        """
        let model = FoldModel(text: text, definition: definition())
        XCTAssertTrue(model.foldableRanges.isEmpty)
        XCTAssertTrue(model.visibility().hiddenRanges.isEmpty)
    }

    func testFoldRangesUseUTF16Offsets() {
        let text = "😀 {\n  body\n}"
        let model = FoldModel(text: text, definition: definition(brackets: allBrackets))

        // The emoji is two UTF-16 code units, so "{" is at offset 3.
        XCTAssertEqual(model.foldableRanges.count, 1)
        XCTAssertEqual(model.foldableRanges[0].range, NSRange(location: 3, length: 10))
        XCTAssertEqual(model.foldableRanges[0].upperBound, text.utf16.count)
    }
}
