import XCTest
import AppKit
import HexpadKit
@testable import Hexpad

final class EditorWiringCoverageTests: XCTestCase {

    private let foldableText = "outer {\n    inner {\n        x\n    }\n}\ntail\n"

    private func makeEditor(_ text: String) -> (editor: EditorContainer, document: DocumentModel) {
        let document = DocumentModel(text: text)
        let editor = EditorContainer()
        editor.frame = NSRect(x: 0, y: 0, width: 800, height: 500)
        editor.layout()
        editor.bind(to: document)
        return (editor, document)
    }

    private func makeController() -> (controller: MainWindowController, window: MainWindow) {
        let window = MainWindow()
        let controller = MainWindowController(window: window)
        window.contentViewController = controller
        _ = controller.view
        return (controller, window)
    }

    func testBindSwapsTextLanguageAndFoldState() {
        let docA = DocumentModel(text: foldableText)
        docA.setLanguage("Swift")
        docA.editorState.hiddenLinesState = HideLinesState(lineRanges: [2...2])
        docA.editorState.tokenStyleState = TokenStyleState(styles: [1: [NSRange(location: 0, length: 5)]])
        docA.setReadOnly(true)

        let docB = DocumentModel(text: "plain text")
        docB.setLanguage("Plain Text")

        let editor = EditorContainer()
        editor.frame = NSRect(x: 0, y: 0, width: 800, height: 500)
        editor.layout()

        editor.bind(to: docA)
        XCTAssertGreaterThan(editor.foldAll(), 0, "doc A has foldable ranges")
        XCTAssertEqual(editor.foldMarkers[1], .collapsed)
        XCTAssertFalse(editor.hiddenLineCharacterSpans.isEmpty, "hidden lines adopted")
        XCTAssertEqual(docA.isReadOnly, true)

        let foldBuilds = editor.foldModelRebuildCount
        let bookmarkBuilds = editor.bookmarkBindCount
        editor.bind(to: docA)
        XCTAssertEqual(editor.foldModelRebuildCount, foldBuilds)
        XCTAssertEqual(editor.bookmarkBindCount, bookmarkBuilds)

        editor.bind(to: docB)
        XCTAssertEqual(editor.textView.string, "plain text")
        XCTAssertTrue(editor.foldMarkers.isEmpty, "plain text has no folds")
        XCTAssertTrue(editor.hiddenLineCharacterSpans.isEmpty, "no hidden lines")
        XCTAssertEqual(docB.isReadOnly, false)

        editor.bind(to: docA)
        XCTAssertEqual(editor.textView.string, foldableText)
        XCTAssertEqual(editor.foldMarkers[1], .collapsed, "fold state restored")
        XCTAssertFalse(editor.hiddenLineCharacterSpans.isEmpty, "hidden lines restored")
        XCTAssertEqual(docA.isReadOnly, true)
        XCTAssertEqual(docA.editorState.tokenStyleState.ranges(for: 1),
                       [NSRange(location: 0, length: 5)], "token style state retained")
    }

    func testBindUnbindCleansUpAndIsDeinitSafe() {
        let doc = DocumentModel(text: "hello\nworld")
        let editor = EditorContainer()
        editor.frame = NSRect(x: 0, y: 0, width: 800, height: 500)
        editor.layout()
        editor.bind(to: doc)
        XCTAssertEqual(editor.textView.string, "hello\nworld")

        editor.bind(to: nil)
        XCTAssertEqual(editor.textView.string, "", "unbound storage is empty")
        XCTAssertTrue(editor.foldMarkers.isEmpty)
        XCTAssertTrue(editor.hiddenLineCharacterSpans.isEmpty)
        editor.bind(to: doc)
        XCTAssertEqual(editor.textView.string, "hello\nworld")
    }

    func testBindHiddenLinesStateAdoptsPersistedRanges() {
        let doc = DocumentModel(text: "a\nb\nc\nd\n")
        doc.editorState.hiddenLinesState = HideLinesState(lineRanges: [2...3])
        let editor = EditorContainer()
        editor.frame = NSRect(x: 0, y: 0, width: 800, height: 500)
        editor.layout()
        editor.bind(to: doc)
        XCTAssertFalse(editor.hiddenLineCharacterSpans.isEmpty)
        XCTAssertEqual(doc.editorState.hiddenLinesState.lineRanges, [2...3])
    }

    func testCaretMoveUpdatesStatusBarViaNotificationChain() {
        let (controller, _) = makeController()
        let textView = try! XCTUnwrap(controller.editorTextView)
        textView.string = "alpha\nbeta\ngamma"
        controller.updateEditor()
        textView.setSelectedRange(NSRange(location: 0, length: 0))

        let bar = try! XCTUnwrap(controller.statusBar)
        textView.setSelectedRange(NSRange(location: 11, length: 0))

        XCTAssertEqual(bar.subviews.compactMap { $0 as? NSTextField }
            .first { $0.stringValue.contains("Ln") }?.stringValue, "Ln 3, Col 1")
    }

    func testSelectionCoveringHiddenBlockUnhidesIt() {
        let doc = DocumentModel(text: "a\nb\nc\nd\n")
        doc.editorState.hiddenLinesState = HideLinesState(lineRanges: [2...3])
        let editor = EditorContainer()
        editor.frame = NSRect(x: 0, y: 0, width: 800, height: 500)
        editor.layout()
        editor.bind(to: doc)
        XCTAssertFalse(editor.hiddenLineCharacterSpans.isEmpty)

        editor.textView.setSelectedRange(NSRange(location: 0, length: 8))
        XCTAssertTrue(doc.editorState.hiddenLinesState.isEmpty,
                      "selecting across a hidden block unhides it")
        XCTAssertTrue(editor.hiddenLineCharacterSpans.isEmpty)
    }

    func testUpdateStatusBarReflectsEditorState() {
        let (controller, _) = makeController()
        let doc = try! XCTUnwrap(controller.tabStore.selectedDocument)
        doc.replaceAllText(with: "one\ntwo")
        let textView = try! XCTUnwrap(controller.editorTextView)
        textView.setSelectedRange(NSRange(location: 4, length: 0))
        controller.updateStatusBar()
        let bar = try! XCTUnwrap(controller.statusBar)
        let positionField = bar.subviews.compactMap { $0 as? NSTextField }
            .first { $0.stringValue.hasPrefix("Ln") }
        XCTAssertEqual(positionField?.stringValue, "Ln 2, Col 1")
    }

    func testFoldToggleUpdatesMarkersAndHiddenRanges() {
        let doc = DocumentModel(text: foldableText)
        doc.setLanguage("Swift")
        let editor = EditorContainer()
        editor.frame = NSRect(x: 0, y: 0, width: 800, height: 500)
        editor.layout()
        editor.bind(to: doc)

        XCTAssertTrue(editor.toggleFold(atLine: 1))
        XCTAssertEqual(editor.foldMarkers[1], .collapsed)
        XCTAssertFalse(editor.foldHiddenRanges.isEmpty)

        XCTAssertTrue(editor.toggleFold(atLine: 1))
        XCTAssertEqual(editor.foldMarkers[1], .expanded)
        XCTAssertTrue(editor.foldHiddenRanges.isEmpty)
    }

    func testFoldAllUnfoldAllThroughContainer() {
        let doc = DocumentModel(text: foldableText)
        doc.setLanguage("Swift")
        let editor = EditorContainer()
        editor.frame = NSRect(x: 0, y: 0, width: 800, height: 500)
        editor.layout()
        editor.bind(to: doc)

        let collapsed = editor.foldAll()
        XCTAssertGreaterThan(collapsed, 0)
        XCTAssertEqual(editor.foldMarkers[1], .collapsed)
        XCTAssertEqual(editor.foldMarkers[2], .collapsed)

        let expanded = editor.unfoldAll()
        XCTAssertGreaterThan(expanded, 0)
        XCTAssertEqual(editor.foldMarkers[1], .expanded)
    }

    func testFoldMarginMarkersMapFoldStartLinesWithoutPerFoldLineScan() {
        let text = "a {\n    b {\n        c\n    }\n}\nd {\n}\n"
        let model = FoldModel(text: text, definition: LexerDefinition(
            language: "Fixture",
            rules: [],
            brackets: [LexerDefinition.BracketPair(open: "{", close: "}")]
        ))
        let markers = FoldMargin.markers(for: model)

        // Fold starts land on lines 1 (outer), 2 (inner), 6 (sibling). The
        // derived markers must agree with `FoldModel.startingLine(of:)`, which
        // replaces the old O(document)-per-fold logicalLine scan.
        XCTAssertEqual(Set(markers.keys), [1, 2, 6])
        XCTAssertEqual(markers[1], .expanded)
        XCTAssertEqual(markers[2], .expanded)
        XCTAssertEqual(markers[6], .expanded)
    }

    func testHandleFoldEditMarksStaleForPlainTextEdit() {
        let doc = DocumentModel(text: "x")
        doc.setLanguage("Swift")
        let editor = EditorContainer()
        editor.frame = NSRect(x: 0, y: 0, width: 800, height: 500)
        editor.layout()
        editor.bind(to: doc)

        let rebuilds = editor.foldModelRebuildCount
        doc.replaceCharacters(in: NSRange(location: 1, length: 0), with: " {\n y\n}\n")

        XCTAssertEqual(editor.foldModelRebuildCount, rebuilds,
                       "edit marks stale without rediscovering folds")
        XCTAssertFalse(editor.foldMarkers.isEmpty,
                       "access rebuilds and discovers the new fold")
        XCTAssertGreaterThan(editor.foldModelRebuildCount, rebuilds)
    }

    func testRefreshFoldModelRebuildsWhenStale() {
        let doc = DocumentModel(text: foldableText)
        doc.setLanguage("Swift")
        let editor = EditorContainer()
        editor.frame = NSRect(x: 0, y: 0, width: 800, height: 500)
        editor.layout()
        editor.bind(to: doc)
        editor.toggleFold(atLine: 1)

        doc.replaceCharacters(in: NSRange(location: 0, length: 0), with: "// h\n")
        XCTAssertTrue(editor.foldMarkers[1] == .collapsed || editor.foldMarkers[2] == .collapsed,
                      "stale model refreshes on marker access")
    }

    func testGutterRowsUpdateAfterEditChangingLineCount() {
        let (editor, document) = makeEditor("a\nb\nc")
        let before = LineNumberGutter.rows(in: editor.textView).count
        document.replaceCharacters(in: NSRange(location: document.textStorage.length, length: 0),
                                   with: "\nd\ne")
        let after = LineNumberGutter.rows(in: editor.textView).count
        XCTAssertGreaterThan(after, before)
    }

    func testBookmarkMarkerTracksLineThroughEditAbove() {
        let (editor, document) = makeEditor("a\nb\nc\nd\n")
        XCTAssertTrue(editor.toggleBookmark(atLine: 3))
        XCTAssertEqual(editor.bookmarkLines, [3])

        document.replaceCharacters(in: NSRange(location: 0, length: 0), with: "x\n")
        XCTAssertEqual(editor.bookmarkLines, [4],
                       "bookmark follows its line through edits above it")
    }

    func testGutterClickSelectsWholeLine() throws {
        let (controller, window) = makeController()
        let doc = try XCTUnwrap(controller.tabStore.selectedDocument)
        doc.replaceAllText(with: "a\nb\nc\nd\n")
        controller.updateEditor()
        let editor = try XCTUnwrap(PreferencesApplier.editorContainer(in: controller.view))
        let ruler = editor.ruler
        let textView = editor.textView

        let layoutManager = try XCTUnwrap(textView.layoutManager)
        let container = try XCTUnwrap(textView.textContainer)
        layoutManager.ensureLayout(for: container)
        let charIndex = GutterGeometry.firstCharIndex(of: 2, in: textView.string)
        let glyphIndex = layoutManager.glyphIndexForCharacter(at: charIndex)
        let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
        let viewPoint = NSPoint(x: LineNumberGutter.markerColumnWidth + LineNumberGutter.bookmarkColumnWidth + 5,
                                y: ruler.bounds.height - fragment.midY)
        let windowPoint = ruler.convert(viewPoint, to: nil)
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: windowPoint,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1))
        ruler.mouseDown(with: event)

        let selected = textView.selectedRange
        let line = GutterGeometry.logicalLine(of: selected.location, in: textView.string)
        XCTAssertEqual(line, 2, "gutter click lands on line 2")
        XCTAssertGreaterThan(selected.length, 0, "a whole line is selected")
    }

    func testMinimapToggleShowsAndHides() {
        let (editor, document) = makeEditor("a\nb\nc")
        _ = document
        editor.setMinimapVisible(false)
        editor.layout()
        XCTAssertTrue(editor.minimap.isHidden)
        XCTAssertEqual(editor.minimap.frame.width, 0, accuracy: 0.5)

        editor.setMinimapVisible(true)
        editor.layout()
        XCTAssertFalse(editor.minimap.isHidden)
        XCTAssertGreaterThan(editor.minimap.frame.width, 0)
        XCTAssertTrue(editor.minimap.isDocumentMapVisible)

        editor.setMinimapVisible(false)
        editor.layout()
        XCTAssertTrue(editor.minimap.isHidden)
    }

    func testMinimapViewportTracksScroll() {
        let (editor, document) = makeEditor((1...200).map(String.init).joined(separator: "\n"))
        _ = document
        editor.setMinimapVisible(true)
        editor.layout()

        editor.minimap.scroll(toMinimapY: editor.minimap.bounds.height)
        let after = editor.scrollView.contentView.bounds.origin.y
        XCTAssertGreaterThan(after, 0, "scrolling minimap moves the editor")
    }

    func testMinimapDrawSmallDirtyRectDoesNotRepaintWholeMap() throws {
        let editor = EditorContainer()
        editor.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        editor.setMinimapVisible(true)
        let document = DocumentModel(text: (1...40).map { "let x\($0) = \($0)" }.joined(separator: "\n"))
        editor.bind(to: document)
        editor.layout()

        let minimap = editor.minimap
        XCTAssertFalse(minimap.isHidden)

        let width = Int(editor.bounds.width)
        let height = Int(editor.bounds.height)
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
                                                 pixelsWide: width,
                                                 pixelsHigh: height,
                                                 bitsPerSample: 8,
                                                 samplesPerPixel: 4,
                                                 hasAlpha: true,
                                                 isPlanar: false,
                                                 colorSpaceName: .deviceRGB,
                                                 bytesPerRow: width * 4,
                                                 bitsPerPixel: 32))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context

        NSColor.magenta.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()

        let dirtyHeight: CGFloat = 20
        context.cgContext.saveGState()
        context.cgContext.translateBy(x: minimap.frame.minX, y: minimap.frame.minY)
        minimap.draw(NSRect(x: 0, y: 0, width: minimap.frame.width, height: dirtyHeight))
        context.cgContext.restoreGState()

        NSGraphicsContext.restoreGraphicsState()

        let checkY = Int(dirtyHeight) + 50
        guard checkY < height else { return }
        let x = Int(minimap.frame.minX) + 5
        if let color = rep.colorAt(x: x, y: checkY)?.usingColorSpace(.deviceRGB) {
            let isSentinel = color.redComponent > 0.9 && color.greenComponent < 0.2 && color.blueComponent > 0.9
            XCTAssertTrue(isSentinel, "a small dirty rect must not repaint the whole minimap")
        }
    }

    func testMinimapClickToNavigate() {
        let (editor, document) = makeEditor((1...20).map(String.init).joined(separator: "\n"))
        _ = document
        editor.setMinimapVisible(true)
        editor.layout()

        editor.minimap.scroll(toMinimapY: editor.minimap.bounds.midY)
        let originAfter = editor.scrollView.contentView.bounds.origin.y
        XCTAssertGreaterThanOrEqual(originAfter, 0)
        XCTAssertTrue(originAfter.isFinite)
    }

    func testTokenStyleStyledRangesRemapOnEdit() {
        let (controller, _) = makeController()
        let doc = try! XCTUnwrap(controller.tabStore.selectedDocument)
        doc.replaceAllText(with: "alpha beta alpha")
        let textView = controller.allPanes[0].editor.textView
        textView.setSelectedRange(NSRange(location: 0, length: 5))

        XCTAssertTrue(controller.performCommand(identifier: "style-all-occurrences-1"))
        XCTAssertEqual(doc.editorState.tokenStyleState.ranges(for: 1).map(\.location), [0, 11])

        doc.replaceCharacters(in: NSRange(location: 0, length: 0), with: "xx ")
        XCTAssertEqual(doc.editorState.tokenStyleState.ranges(for: 1).map(\.location), [3, 14],
                       "styled ranges remap on edit")
        XCTAssertEqual(textView.tokenStyleState.ranges(for: 1).map(\.location), [3, 14],
                       "text view re-applies remapped styles")
    }

    func testTokenStyleClearAndClearAll() {
        let (controller, _) = makeController()
        let doc = try! XCTUnwrap(controller.tabStore.selectedDocument)
        doc.replaceAllText(with: "alpha beta alpha")
        let textView = controller.allPanes[0].editor.textView
        textView.setSelectedRange(NSRange(location: 0, length: 5))

        XCTAssertTrue(controller.performCommand(identifier: "style-all-occurrences-2"))
        XCTAssertFalse(doc.editorState.tokenStyleState.isEmpty)

        XCTAssertTrue(controller.performCommand(identifier: "clear-style-2"))
        XCTAssertTrue(doc.editorState.tokenStyleState.ranges(for: 2).isEmpty)

        textView.setSelectedRange(NSRange(location: 0, length: 5))
        XCTAssertTrue(controller.performCommand(identifier: "style-all-occurrences-3"))
        XCTAssertTrue(controller.performCommand(identifier: "clear-style-all"))
        XCTAssertTrue(doc.editorState.tokenStyleState.isEmpty)
        XCTAssertTrue(textView.tokenStyleState.isEmpty)
    }
}
