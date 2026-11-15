import XCTest
import AppKit
import HexpadKit
@testable import Hexpad

/// State-driving tests for the app-side multi-caret wiring. They exercise the
/// real editor container and its `NSTextView` subclass rather than duplicating
/// the gesture logic, but assert model state instead of pixels.
final class MultiCaretWiringTests: XCTestCase {

    private func makeEditor(_ text: String) -> (editor: EditorContainer, document: DocumentModel) {
        let document = DocumentModel(text: text)
        let editor = EditorContainer()
        editor.bind(to: document)
        return (editor, document)
    }

    // MARK: - Placing and collapsing carets

    func testAdditionalCaretIsStoredInDocumentOrder() {
        let (editor, _) = makeEditor("one\ntwo\nthree")
        editor.textView.setSelectedRange(NSRange(location: 4, length: 0))

        editor.placeAdditionalCaret(atCharacterIndex: 0)

        XCTAssertEqual(editor.multiCaretState.carets,
                       [NSRange(location: 0, length: 0),
                        NSRange(location: 4, length: 0)])
        XCTAssertEqual(editor.textView.selectedRange, NSRange(location: 0, length: 0),
                       "the text view mirrors the primary (first) caret")
    }

    func testClickingPrimaryPositionAgainCollapsesToSingleCaret() {
        let (editor, _) = makeEditor("one\ntwo\nthree")
        editor.textView.setSelectedRange(NSRange(location: 0, length: 0))
        editor.placeAdditionalCaret(atCharacterIndex: 4)
        XCTAssertEqual(editor.multiCaretState.count, 2)

        editor.placeAdditionalCaret(atCharacterIndex: 0)

        XCTAssertEqual(editor.multiCaretState.carets, [NSRange(location: 0, length: 0)])
    }

    func testClickingAnExistingExtraCaretTogglesItOff() {
        let (editor, _) = makeEditor("one\ntwo\nthree")
        editor.textView.setSelectedRange(NSRange(location: 0, length: 0))
        editor.placeAdditionalCaret(atCharacterIndex: 4)
        editor.placeAdditionalCaret(atCharacterIndex: 8)
        XCTAssertEqual(editor.multiCaretState.count, 3)

        editor.placeAdditionalCaret(atCharacterIndex: 4)

        XCTAssertEqual(editor.multiCaretState.carets,
                       [NSRange(location: 0, length: 0),
                        NSRange(location: 8, length: 0)])
    }

    func testEscapeCollapsesExtraCarets() {
        let (editor, _) = makeEditor("one\ntwo")
        editor.textView.setSelectedRange(NSRange(location: 0, length: 0))
        editor.placeAdditionalCaret(atCharacterIndex: 4)
        XCTAssertEqual(editor.multiCaretState.count, 2)

        editor.textView.cancelOperation(nil)

        XCTAssertEqual(editor.multiCaretState.carets, [NSRange(location: 0, length: 0)])
    }

    // MARK: - Editing through MultiCaretApplier

    func testTypingAppliesAtEveryCaretAsOneUndoStep() {
        let (editor, document) = makeEditor("ab")
        document.undoManager.removeAllActions()
        editor.textView.setSelectedRange(NSRange(location: 0, length: 0))
        editor.placeAdditionalCaret(atCharacterIndex: 1)

        editor.textView.insertText("X", replacementRange: editor.textView.selectedRange)

        XCTAssertEqual(document.text, "XaXb")
        XCTAssertEqual(editor.multiCaretState.carets,
                       [NSRange(location: 1, length: 0),
                        NSRange(location: 3, length: 0)])

        document.undoManager.undo()
        XCTAssertEqual(document.text, "ab", "the whole action must undo in one step")
    }

    func testBackspaceDeletesAtEveryCaretAsOneUndoStep() {
        let (editor, document) = makeEditor("abc\ndef")
        document.undoManager.removeAllActions()
        editor.textView.setSelectedRange(NSRange(location: 3, length: 0))
        editor.placeAdditionalCaret(atCharacterIndex: 7)
        XCTAssertEqual(editor.multiCaretState.carets,
                       [NSRange(location: 3, length: 0),
                        NSRange(location: 7, length: 0)])

        editor.textView.deleteBackward(nil)

        XCTAssertEqual(document.text, "ab\nde")
        XCTAssertEqual(editor.multiCaretState.carets,
                       [NSRange(location: 2, length: 0),
                        NSRange(location: 5, length: 0)])

        document.undoManager.undo()
        XCTAssertEqual(document.text, "abc\ndef")
    }

    func testPasteAppliesAtEveryCaretAsOneUndoStep() {
        let (editor, document) = makeEditor("ab\ncd")
        document.undoManager.removeAllActions()
        editor.textView.setSelectedRange(NSRange(location: 1, length: 0))
        editor.placeAdditionalCaret(atCharacterIndex: 4)

        let pasteboard = NSPasteboard.general
        let saved = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        pasteboard.setString("Z", forType: .string)
        defer {
            pasteboard.clearContents()
            if let saved {
                pasteboard.setString(saved, forType: .string)
            }
        }

        editor.textView.paste(nil)

        XCTAssertEqual(document.text, "aZb\ncZd")
        document.undoManager.undo()
        XCTAssertEqual(document.text, "ab\ncd")
    }

    // MARK: - Column selection

    func testOptionDragRectangleBecomesMultiCaretStateAndEdits() {
        let text = "abc\ndef\nghi"
        let (editor, document) = makeEditor(text)
        document.undoManager.removeAllActions()

        editor.textView.setSelectedRange(NSRange(location: 1, length: 0))
        editor.beginColumnSelection(atCharacterIndex: 1)
        editor.updateColumnSelection(toCharacterIndex: 6)
        editor.endColumnSelection()

        let expected = ColumnEditing.carets(
            in: text,
            rectangle: ColumnRectangle(start: TextPoint(line: 0, column: 1),
                                       end: TextPoint(line: 1, column: 2))
        )
        XCTAssertEqual(editor.multiCaretState, expected)
        XCTAssertEqual(editor.multiCaretState.carets,
                       [NSRange(location: 1, length: 1),
                        NSRange(location: 5, length: 1)])

        editor.applyMultiCaretInsertion("X")

        XCTAssertEqual(document.text, "aXc\ndXf\nghi")
        document.undoManager.undo()
        XCTAssertEqual(document.text, text)
    }

    // MARK: - Selection notification arbitration

    func testOrdinarySelectionChangeCollapsesExtraCarets() {
        let (editor, _) = makeEditor("one\ntwo\nthree")
        editor.textView.setSelectedRange(NSRange(location: 0, length: 0))
        editor.placeAdditionalCaret(atCharacterIndex: 4)
        XCTAssertEqual(editor.multiCaretState.count, 2)

        editor.textView.setSelectedRange(NSRange(location: 2, length: 0))

        XCTAssertEqual(editor.multiCaretState.carets, [NSRange(location: 2, length: 0)])
    }

    func testSelectionNotificationEchoingPrimaryKeepsExtraCarets() {
        let (editor, _) = makeEditor("one\ntwo\nthree")
        editor.textView.setSelectedRange(NSRange(location: 0, length: 0))
        editor.placeAdditionalCaret(atCharacterIndex: 4)
        XCTAssertEqual(editor.multiCaretState.count, 2)

        // Simulate a late notification that only reports the primary caret.
        NotificationCenter.default.post(
            name: NSNotification.Name("NSTextViewDidChangeSelectionNotification"),
            object: editor.textView
        )

        XCTAssertEqual(editor.multiCaretState.count, 2,
                       "an echo of the primary selection must not fight the caret state")
    }

    // MARK: - Minimal commit diff

    func testTextChangeIsTheSmallestReplacement() {
        let change = MultiCaretEditing.change(from: "abc", to: "aXc")
        XCTAssertEqual(change, MultiCaretEditing.TextChange(range: NSRange(location: 1, length: 1),
                                                            replacement: "X"))
    }

    func testTextChangeHandlesInsertionAtEndAndEmptyDocuments() {
        XCTAssertEqual(MultiCaretEditing.change(from: "ab", to: "abZ"),
                       MultiCaretEditing.TextChange(range: NSRange(location: 2, length: 0),
                                                    replacement: "Z"))
        XCTAssertEqual(MultiCaretEditing.change(from: "", to: "Z"),
                       MultiCaretEditing.TextChange(range: NSRange(location: 0, length: 0),
                                                    replacement: "Z"))
        XCTAssertNil(MultiCaretEditing.change(from: "same", to: "same"))
    }
}

// MARK: - Fold gutter

/// Wiring tests for the fold margin and folded-document rendering. They assert
/// marker/model state and laid-out line rows rather than pixels, so they cover
/// the integration without depending on a window server.
final class FoldGutterTests: XCTestCase {

    /// `{` on line 1, close on line 3, trailing line 4.
    private let nestedText = "func f() {\n    let x = 1\n}\nlet y = 2\n"

    private func makeEditor(_ text: String,
                            language: Language = .swift) -> (editor: EditorContainer,
                                                              document: DocumentModel) {
        let document = DocumentModel(text: text)
        document.setLanguage(language.rawValue)
        let editor = EditorContainer()
        editor.bind(to: document)
        return (editor, document)
    }

    private func visibleLines(_ editor: EditorContainer) -> [Int] {
        let length = (editor.textView.string as NSString).length
        return LineNumberGutter
            .rows(in: editor.textView, characterRange: NSRange(location: 0, length: length))
            .map(\.line)
    }

    // MARK: - Markers

    func testFoldableLinesGetExpandedMarkers() {
        let (editor, _) = makeEditor(nestedText)

        XCTAssertEqual(editor.foldMarkers, [1: .expanded],
                       "only the multi-line brace fold on line 1 is foldable")
        XCTAssertEqual(editor.ruler.markerState(forLine: 1), .expanded)
        XCTAssertNil(editor.ruler.markerState(forLine: 2))
    }

    func testPlainTextHasNoMarkers() {
        let (editor, _) = makeEditor("{\n}", language: .plain)

        XCTAssertTrue(editor.foldMarkers.isEmpty)
        XCTAssertFalse(editor.toggleFold(atLine: 1), "plain text has no foldable ranges")
        XCTAssertTrue(editor.foldHiddenRanges.isEmpty)
    }

    func testToggleFoldUpdatesMarkerState() {
        let (editor, _) = makeEditor(nestedText)

        XCTAssertTrue(editor.toggleFold(atLine: 1))
        XCTAssertEqual(editor.foldMarkers[1], .collapsed)
        XCTAssertEqual(editor.ruler.markerState(forLine: 1), .collapsed)

        XCTAssertTrue(editor.toggleFold(atLine: 1))
        XCTAssertEqual(editor.foldMarkers[1], .expanded)
        XCTAssertEqual(editor.ruler.markerState(forLine: 1), .expanded)
    }

    func testTogglingALineWithoutAFoldIsANoOp() {
        let (editor, _) = makeEditor(nestedText)

        XCTAssertFalse(editor.toggleFold(atLine: 2))
        XCTAssertEqual(editor.foldMarkers, [1: .expanded])
        XCTAssertTrue(editor.foldHiddenRanges.isEmpty)
    }

    // MARK: - Collapsed content

    func testCollapsedFoldHidesContentRanges() {
        let (editor, _) = makeEditor(nestedText)
        XCTAssertTrue(editor.foldHiddenRanges.isEmpty)

        editor.toggleFold(atLine: 1)

        // Hidden from the newline that ends line 1 through the closing brace:
        // exactly the fold's interior plus its terminator, keeping line 1 visible.
        XCTAssertEqual(editor.foldHiddenRanges, [NSRange(location: 10, length: 16)])

        editor.toggleFold(atLine: 1)
        XCTAssertTrue(editor.foldHiddenRanges.isEmpty, "expanding restores the full layout")
    }

    func testCollapsedFoldRemovesHiddenRowsFromLayout() {
        let (editor, _) = makeEditor(nestedText)
        XCTAssertEqual(visibleLines(editor), [1, 2, 3, 4])

        editor.toggleFold(atLine: 1)

        XCTAssertEqual(visibleLines(editor), [1, 4],
                       "folded lines disappear from layout; numbering keeps document lines")
        XCTAssertEqual(LineNumberGutter.rows(in: editor.textView,
                                             characterRange: NSRange(location: 0, length: 39)).map(\.line),
                       [1, 4])
    }

    func testNestedFoldInsideCollapsedOuterFoldIsHidden() {
        let text = "outer {\n    inner {\n        x\n    }\n}\ntail\n"
        let (editor, _) = makeEditor(text)
        XCTAssertEqual(Set(editor.foldMarkers.keys), [1, 2])

        editor.toggleFold(atLine: 1)

        XCTAssertEqual(editor.foldMarkers[1], .collapsed)
        XCTAssertEqual(editor.foldMarkers[2], .expanded,
                       "inner marker state is retained even while its line is hidden")
        XCTAssertEqual(visibleLines(editor), [1, 6])
    }

    // MARK: - Line numbers

    func testLineNumbersStayCorrectAfterCollapse() {
        let (editor, _) = makeEditor(nestedText)

        editor.toggleFold(atLine: 1)

        let rows = LineNumberGutter.rows(in: editor.textView,
                                         characterRange: NSRange(location: 0, length: 39))
        XCTAssertEqual(rows.map(\.line), [1, 4])
        XCTAssertEqual(rows.count, 2)
    }

    func testLineNumberWidthLeavesRoomForTheMarkerColumn() {
        XCTAssertEqual(LineNumberGutter.markerColumnWidth, 16)
        XCTAssertEqual(LineNumberGutter.width,
                       LineNumberGutter.numberColumnWidth + LineNumberGutter.markerColumnWidth)
        XCTAssertGreaterThan(LineNumberGutter.width, LineNumberGutter.numberColumnWidth)
    }

    // MARK: - Per-document state

    func testFoldStateIsRememberedPerDocument() {
        let (editor, first) = makeEditor(nestedText)
        let second = DocumentModel(text: "other {\n    body\n}\n")
        second.setLanguage(Language.swift.rawValue)

        editor.toggleFold(atLine: 1)
        XCTAssertEqual(editor.foldMarkers[1], .collapsed)

        editor.bind(to: second)
        XCTAssertEqual(editor.foldMarkers[1], .expanded,
                       "a different document starts unfolded")
        XCTAssertTrue(editor.foldHiddenRanges.isEmpty)

        editor.bind(to: first)
        XCTAssertEqual(editor.foldMarkers[1], .collapsed,
                       "returning to a tab restores its collapsed folds")
        XCTAssertFalse(editor.foldHiddenRanges.isEmpty)
    }

    func testEditingWhileCollapsedRemapsHiddenRanges() {
        let (editor, document) = makeEditor(nestedText)
        editor.toggleFold(atLine: 1)
        XCTAssertEqual(editor.foldHiddenRanges, [NSRange(location: 10, length: 16)])

        document.replaceCharacters(in: NSRange(location: 0, length: 0), with: "// header\n")

        XCTAssertEqual(editor.foldHiddenRanges, [NSRange(location: 20, length: 16)],
                       "the fold shifts with text inserted before it")
        XCTAssertEqual(editor.foldMarkers[2], .collapsed)
    }

    // MARK: - Marker clicks

    private func markerPoint(forLine line: Int, x: CGFloat,
                             in editor: EditorContainer) -> NSPoint? {
        let length = (editor.textView.string as NSString).length
        guard let row = LineNumberGutter
            .rows(in: editor.textView, characterRange: NSRange(location: 0, length: length))
            .first(where: { $0.line == line }) else { return nil }
        return NSPoint(x: x,
                       y: editor.ruler.bounds.height - row.topY - row.height / 2)
    }

    func testMarkerClickTogglesFoldAndIsConsumed() {
        let (editor, _) = makeEditor(nestedText)
        guard let point = markerPoint(forLine: 1,
                                      x: LineNumberGutter.markerColumnWidth / 2,
                                      in: editor) else {
            return XCTFail("no laid-out row for line 1")
        }

        XCTAssertTrue(editor.ruler.handleFoldMarkerClick(at: point))
        XCTAssertEqual(editor.foldMarkers[1], .collapsed,
                       "the marker press toggled the fold through the model")
        XCTAssertEqual(editor.ruler.markerState(forLine: 1), .collapsed)
    }

    func testNumberColumnPressIsLeftForLineSelection() {
        let (editor, _) = makeEditor(nestedText)
        guard let point = markerPoint(forLine: 1,
                                      x: LineNumberGutter.markerColumnWidth + 8,
                                      in: editor) else {
            return XCTFail("no laid-out row for line 1")
        }

        XCTAssertFalse(editor.ruler.handleFoldMarkerClick(at: point),
                       "the number column keeps its pre-existing line-click behavior")
        XCTAssertEqual(editor.foldMarkers[1], .expanded)
        XCTAssertTrue(editor.foldHiddenRanges.isEmpty)
    }

    func testMarkerColumnPressOnANonFoldableLineFallsThrough() {
        let (editor, _) = makeEditor(nestedText)
        guard let point = markerPoint(forLine: 2,
                                      x: LineNumberGutter.markerColumnWidth / 2,
                                      in: editor) else {
            return XCTFail("no laid-out row for line 2")
        }

        XCTAssertFalse(editor.ruler.handleFoldMarkerClick(at: point),
                       "no marker means the press still selects the line")
        XCTAssertEqual(editor.foldMarkers, [1: .expanded])
    }

    // MARK: - Glyph hider

    func testGlyphHiderSuppressesHiddenLineFragments() {
        let storage = NSTextStorage(string: "aaa\nbbb\nccc\n")
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 100, height: 10_000))
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)

        func fragmentCount() -> Int {
            layoutManager.ensureLayout(for: container)
            var count = 0
            layoutManager.enumerateLineFragments(
                forGlyphRange: NSRange(location: 0, length: layoutManager.numberOfGlyphs)
            ) { _, _, _, _, _ in count += 1 }
            return count
        }

        XCTAssertEqual(fragmentCount(), 3)

        let hider = FoldGlyphHider()
        layoutManager.delegate = hider
        XCTAssertTrue(hider.setHiddenRanges([NSRange(location: 3, length: 4)]),
                      "hiding the newline after line 1 and line 2's content")
        layoutManager.invalidateGlyphs(forCharacterRange: NSRange(location: 0, length: storage.length),
                                       changeInLength: 0,
                                       actualCharacterRange: nil)
        layoutManager.invalidateLayout(forCharacterRange: NSRange(location: 0, length: storage.length),
                                       actualCharacterRange: nil)

        XCTAssertEqual(fragmentCount(), 2)
        XCTAssertTrue(hider.isHidden(characterIndex: 3))
        XCTAssertFalse(hider.isHidden(characterIndex: 0))
        XCTAssertFalse(hider.setHiddenRanges([NSRange(location: 3, length: 4)]),
                       "unchanged ranges report no change")
    }
}

// MARK: - Fold persistence

/// Persistence wiring for collapsed folds. `FoldGutterTests` covers the live
/// in-memory state; these tests cover the round trip through
/// `DocumentModel.foldState` and the real session file, which is what decides
/// whether collapsed folds survive an app restart.
final class FoldPersistenceTests: XCTestCase {

    /// `{` on line 1, close on line 3, trailing line 4. Collapsing line 1 hides
    /// the range 10..<26 and leaves lines 1 and 4 visible.
    private let nestedText = "func f() {\n    let x = 1\n}\nlet y = 2\n"

    private var sessionDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Keep the round-trip test away from the developer's real session file.
        sessionDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hexpad-fold-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sessionDirectory,
                                                withIntermediateDirectories: true)
        SessionStore.overrideDirectory = sessionDirectory
    }

    override func tearDownWithError() throws {
        SessionStore.overrideDirectory = nil
        if let sessionDirectory {
            try? FileManager.default.removeItem(at: sessionDirectory)
        }
        try super.tearDownWithError()
    }

    private func makeEditor(_ text: String,
                            language: Language = .swift) -> (editor: EditorContainer,
                                                              document: DocumentModel) {
        let document = DocumentModel(text: text)
        document.setLanguage(language.rawValue)
        let editor = EditorContainer()
        editor.bind(to: document)
        return (editor, document)
    }

    // MARK: - Write-through

    func testTogglingAFoldWritesThroughToTheDocument() throws {
        let (editor, document) = makeEditor(nestedText)
        XCTAssertTrue(document.foldState.isEmpty)
        let foldRange = try XCTUnwrap(editor.foldModel?.foldableRanges.first?.range)

        XCTAssertTrue(editor.toggleFold(atLine: 1))

        XCTAssertFalse(document.foldState.isEmpty,
                       "the collapsed state must reach the persisted projection")
        XCTAssertEqual(document.foldState, editor.foldModel?.foldState)
        XCTAssertTrue(document.foldState.isCollapsed(foldRange))

        XCTAssertTrue(editor.toggleFold(atLine: 1))
        XCTAssertTrue(document.foldState.isEmpty,
                      "expanding writes the empty state back too")
    }

    func testRemappingAnEditWritesThroughToTheDocument() throws {
        let (editor, document) = makeEditor(nestedText)
        XCTAssertTrue(editor.toggleFold(atLine: 1))
        let before = document.foldState
        let foldedRange = try XCTUnwrap(before.collapsedRanges.first?.range)

        // Edit the shared buffer; the container's storage observer remaps the
        // fold to follow the insertion.
        document.replaceCharacters(in: NSRange(location: 0, length: 0),
                                   with: "// header\n")

        XCTAssertNotEqual(document.foldState, before)
        let shifted = NSRange(location: foldedRange.location + 10,
                              length: foldedRange.length)
        XCTAssertTrue(document.foldState.isCollapsed(shifted),
                      "the remapped range is persisted, not just held in memory")
        XCTAssertEqual(document.foldState, editor.foldModel?.foldState)
    }

    // MARK: - Tab switches

    func testFoldSurvivesBindingAnotherDocumentAndBack() {
        let (editor, docA) = makeEditor(nestedText)
        let docB = DocumentModel(text: "other {\n    body\n}\n")
        docB.setLanguage(Language.swift.rawValue)

        XCTAssertTrue(editor.toggleFold(atLine: 1))
        let persistedA = docA.foldState
        XCTAssertFalse(persistedA.isEmpty)

        editor.bind(to: docB)
        XCTAssertEqual(editor.foldMarkers[1], .expanded,
                       "a different document starts unfolded")
        XCTAssertTrue(editor.foldHiddenRanges.isEmpty)
        XCTAssertTrue(docB.foldState.isEmpty,
                      "binding doc B must not inherit doc A's folds")

        editor.bind(to: docA)
        XCTAssertEqual(editor.foldMarkers[1], .collapsed,
                       "returning to a tab restores its collapsed folds")
        XCTAssertFalse(editor.foldHiddenRanges.isEmpty)
        XCTAssertEqual(docA.foldState, persistedA)
    }

    func testFreshContainerSeedsFromTheDocumentsPersistedFoldState() {
        let (firstEditor, document) = makeEditor(nestedText)
        XCTAssertTrue(firstEditor.toggleFold(atLine: 1))
        let persisted = document.foldState
        XCTAssertFalse(persisted.isEmpty)

        // A container that has never seen this document (as after a restart)
        // must adopt the document's persisted projection on bind.
        let freshEditor = EditorContainer()
        freshEditor.bind(to: document)

        XCTAssertEqual(freshEditor.foldModel?.foldState, persisted)
        XCTAssertEqual(freshEditor.foldMarkers[1], .collapsed)
        XCTAssertFalse(freshEditor.foldHiddenRanges.isEmpty)
    }

    // MARK: - Session round-trip

    func testFoldStateSurvivesSessionSaveAndRestoreIntoAFreshContainer() throws {
        let (editor, document) = makeEditor(nestedText)
        XCTAssertTrue(editor.toggleFold(atLine: 1))
        let collapsed = document.foldState
        XCTAssertFalse(collapsed.isEmpty)

        let store = TabStore()
        store.addDocument(document)
        try SessionStore.save(store)

        let restored = try XCTUnwrap(SessionStore.restore())
        let restoredDocument = try XCTUnwrap(restored.tabs.documents.first)
        XCTAssertEqual(restoredDocument.foldState, collapsed,
                       "session.json carries the collapsed range")
        XCTAssertEqual(restoredDocument.language, Language.swift.rawValue)

        // Bind a brand-new container to the restored document: this is the
        // app-restart path, with no in-memory fold state to fall back on.
        let freshEditor = EditorContainer()
        freshEditor.bind(to: restoredDocument)

        XCTAssertEqual(freshEditor.foldMarkers[1], .collapsed)
        XCTAssertFalse(freshEditor.foldHiddenRanges.isEmpty,
                       "the fold is still collapsed after a restart")
        XCTAssertEqual(freshEditor.foldModel?.foldState, collapsed)
    }
}
