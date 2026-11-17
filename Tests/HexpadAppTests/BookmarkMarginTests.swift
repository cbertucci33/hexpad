import XCTest
import AppKit
import HexpadKit
@testable import Hexpad

/// App-side coverage for the bookmark margin slice.
///
/// These tests drive the real `EditorContainer`, `LineNumberGutter`, and
/// `MainWindowController` (like `MenuWiringTests` / `MultiCaretWiringTests`)
/// instead of duplicating their logic, and assert model state rather than
/// pixels. They close the gap between the Kit-level `BookmarkModel` /
/// `BookmarkCommandTests` and the app wiring that persists bookmarks per
/// document, paints gutter markers, and routes the Text-menu commands.
final class BookmarkMarginTests: XCTestCase {

    private var keybindingDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Menu construction must not read the developer's real keybindings.json.
        keybindingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hexpad-bookmark-tests-\(UUID().uuidString)")
        KeybindingStore.overrideDirectory = keybindingDirectory
    }

    override func tearDownWithError() throws {
        KeybindingStore.overrideDirectory = nil
        if let keybindingDirectory {
            try? FileManager.default.removeItem(at: keybindingDirectory)
        }
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    /// A laid-out editor bound to a fresh document. The editor needs a non-zero
    /// frame so the gutter has geometry for the click test.
    private func makeEditor(_ text: String) -> (editor: EditorContainer, document: DocumentModel) {
        let document = DocumentModel(text: text)
        let editor = EditorContainer()
        editor.frame = NSRect(x: 0, y: 0, width: 800, height: 500)
        editor.layout()
        editor.bind(to: document)
        return (editor, document)
    }

    /// The same controller fixture `MenuWiringTests` uses: a real window and
    /// controller with the first tab loaded.
    private func makeController() -> (controller: MainWindowController, window: MainWindow) {
        let window = MainWindow()
        let controller = MainWindowController(window: window)
        window.contentViewController = controller
        _ = controller.view // loadView + viewDidLoad; creates the first tab
        return (controller, window)
    }

    /// A point inside the gutter's bookmark column for `line`, derived from the
    /// real line-fragment geometry (the gutter is non-flipped, the text view is
    /// flipped, so Y is mirrored).
    private func bookmarkClickPoint(line: Int,
                                    in editor: EditorContainer) throws -> NSPoint {
        let textView = editor.textView
        let layoutManager = try XCTUnwrap(textView.layoutManager)
        let container = try XCTUnwrap(textView.textContainer)
        layoutManager.ensureLayout(for: container)

        let characterIndex = GutterGeometry.firstCharIndex(of: line, in: textView.string)
        let glyphIndex = layoutManager.glyphIndexForCharacter(at: characterIndex)
        let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex,
                                                      effectiveRange: nil)
        let x = LineNumberGutter.markerColumnWidth
            + LineNumberGutter.bookmarkColumnWidth / 2
        return NSPoint(x: x, y: editor.ruler.bounds.height - fragment.midY)
    }

    // MARK: - Bind/unbind round-trip and tab switches

    func testBookmarkSurvivesBindUnbindRoundTripThroughDocumentModel() {
        let docA = DocumentModel(text: "alpha\nbeta\ngamma")
        let docB = DocumentModel(text: "one\ntwo\nthree")
        let editor = EditorContainer()
        editor.frame = NSRect(x: 0, y: 0, width: 800, height: 500)
        editor.layout()

        editor.bind(to: docA)
        XCTAssertTrue(editor.toggleBookmark(atLine: 2))
        XCTAssertEqual(editor.bookmarkLines, [2])
        XCTAssertEqual(docA.bookmarkState.lines, [2],
                       "toggling writes through to the document immediately")

        editor.bind(to: docB)
        XCTAssertTrue(editor.bookmarkLines.isEmpty,
                      "a different document starts with no markers")
        XCTAssertTrue(docB.bookmarkState.isEmpty)

        editor.bind(to: docA)
        XCTAssertEqual(editor.bookmarkLines, [2],
                       "rebinding restores the tab's bookmarks")
        XCTAssertTrue(editor.ruler.isBookmarked(line: 2))
        XCTAssertEqual(docA.bookmarkState.lines, [2])

        // Unbinding flushes the live model into the document so a later bind
        // (or a session save) sees the same state.
        editor.bind(to: nil)
        XCTAssertTrue(editor.bookmarkLines.isEmpty)
        XCTAssertEqual(docA.bookmarkState.lines, [2])

        editor.bind(to: docA)
        XCTAssertEqual(editor.bookmarkLines, [2])
    }

    func testBookmarkSurvivesControllerTabSwitch() throws {
        let (controller, _) = makeController()
        let docA = DocumentModel(text: "a\nb\nc")
        let docB = DocumentModel(text: "x\ny\nz")
        controller.tabStore.documents = [docA, docB]
        controller.tabStore.selectedIndex = 0
        controller.updateEditor()

        let textView = try XCTUnwrap(controller.editorTextView)
        textView.setSelectedRange(NSRange(location: 2, length: 0)) // line 2
        XCTAssertTrue(controller.performCommand(identifier: "bookmark-toggle"))
        XCTAssertEqual(docA.bookmarkState.lines, [2])
        XCTAssertTrue(docB.bookmarkState.isEmpty)

        // Switch to tab B: it must not inherit A's marker.
        controller.tabStore.selectedIndex = 1
        controller.updateEditor()
        XCTAssertTrue(docB.bookmarkState.isEmpty)
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertTrue(controller.performCommand(identifier: "bookmark-toggle"))
        XCTAssertEqual(docB.bookmarkState.lines, [1])
        XCTAssertEqual(docA.bookmarkState.lines, [2], "tab B does not touch tab A")

        // Switch back to tab A: its bookmark is still there (clear-all only
        // reports a change when the state is non-empty).
        controller.tabStore.selectedIndex = 0
        controller.updateEditor()
        XCTAssertTrue(controller.performCommand(identifier: "bookmark-clear-all"))
        XCTAssertTrue(docA.bookmarkState.isEmpty)
        XCTAssertEqual(docB.bookmarkState.lines, [1])
    }

    // MARK: - Gutter marker state

    func testToggleBookmarkUpdatesTheMarkerStateTheGutterReads() {
        let (editor, document) = makeEditor("one\ntwo\nthree")

        XCTAssertTrue(editor.bookmarkLines.isEmpty)
        XCTAssertFalse(editor.ruler.isBookmarked(line: 2))

        XCTAssertTrue(editor.toggleBookmark(atLine: 2))
        XCTAssertEqual(editor.bookmarkLines, [2])
        XCTAssertTrue(editor.ruler.isBookmarked(line: 2))
        XCTAssertFalse(editor.ruler.isBookmarked(line: 1))
        XCTAssertFalse(editor.ruler.isBookmarked(line: 3))
        XCTAssertEqual(document.bookmarkState.lines, [2])

        // Toggling again removes the marker.
        XCTAssertTrue(editor.toggleBookmark(atLine: 2))
        XCTAssertTrue(editor.bookmarkLines.isEmpty)
        XCTAssertFalse(editor.ruler.isBookmarked(line: 2))
        XCTAssertTrue(document.bookmarkState.isEmpty)

        // Lines outside the document are rejected without changing state.
        XCTAssertFalse(editor.toggleBookmark(atLine: 0))
        XCTAssertFalse(editor.toggleBookmark(atLine: 4))
        XCTAssertTrue(editor.bookmarkLines.isEmpty)
    }

    func testHandleBookmarkClickTogglesTheClickedLine() throws {
        let (editor, document) = makeEditor("alpha\nbeta\ngamma")

        let point = try bookmarkClickPoint(line: 2, in: editor)
        XCTAssertTrue(editor.ruler.handleBookmarkClick(at: point))
        XCTAssertEqual(editor.bookmarkLines, [2])
        XCTAssertEqual(document.bookmarkState.lines, [2])
        XCTAssertTrue(editor.ruler.isBookmarked(line: 2))

        XCTAssertTrue(editor.ruler.handleBookmarkClick(at: point))
        XCTAssertTrue(editor.bookmarkLines.isEmpty)
        XCTAssertTrue(document.bookmarkState.isEmpty)

        // A click outside the bookmark column is not consumed and does not
        // scroll or toggle anything.
        let foldColumn = NSPoint(x: 1, y: point.y)
        XCTAssertFalse(editor.ruler.handleBookmarkClick(at: foldColumn))
        let numberColumn = NSPoint(x: LineNumberGutter.markerColumnWidth
                                     + LineNumberGutter.bookmarkColumnWidth + 1,
                                   y: point.y)
        XCTAssertFalse(editor.ruler.handleBookmarkClick(at: numberColumn))
        XCTAssertTrue(editor.bookmarkLines.isEmpty)
    }

    // MARK: - performCommand routing

    func testPerformCommandRoutesBookmarkToggle() throws {
        let (controller, _) = makeController()
        let doc = try XCTUnwrap(controller.tabStore.selectedDocument)
        let textView = try XCTUnwrap(controller.editorTextView)

        doc.replaceAllText(with: "alpha\nbeta\ngamma")
        textView.setSelectedRange(NSRange(location: 7, length: 0)) // line 2

        XCTAssertTrue(controller.performCommand(identifier: "bookmark-toggle"))
        XCTAssertEqual(doc.bookmarkState.lines, [2])
        XCTAssertEqual(doc.text, "alpha\nbeta\ngamma", "toggle only changes bookmarks")

        XCTAssertTrue(controller.performCommand(identifier: "bookmark-toggle"))
        XCTAssertTrue(doc.bookmarkState.isEmpty)
    }

    func testPerformCommandRoutesBookmarkNavigation() throws {
        let (controller, _) = makeController()
        let doc = try XCTUnwrap(controller.tabStore.selectedDocument)
        let textView = try XCTUnwrap(controller.editorTextView)

        doc.replaceAllText(with: "a\nb\nc\nd")
        doc.bookmarkState = BookmarkState(bookmarks: [Bookmark(line: 1),
                                                     Bookmark(line: 3)])
        textView.setSelectedRange(NSRange(location: 0, length: 0))

        XCTAssertTrue(controller.performCommand(identifier: "bookmark-next"))
        XCTAssertEqual(textView.selectedRange, NSRange(location: 4, length: 0),
                       "next jumps to the start of line 3")

        XCTAssertTrue(controller.performCommand(identifier: "bookmark-prev"))
        XCTAssertEqual(textView.selectedRange, NSRange(location: 0, length: 0),
                       "previous jumps back to the start of line 1")

        XCTAssertEqual(doc.bookmarkState.lines, [1, 3],
                       "navigation leaves the text and bookmarks alone")
    }

    func testPerformCommandRoutesClearAllBookmarks() throws {
        let (controller, _) = makeController()
        let doc = try XCTUnwrap(controller.tabStore.selectedDocument)

        doc.replaceAllText(with: "a\nb\nc")
        doc.bookmarkState = BookmarkState(bookmarks: [Bookmark(line: 1),
                                                     Bookmark(line: 3)])

        XCTAssertTrue(controller.performCommand(identifier: "bookmark-clear-all"))
        XCTAssertTrue(doc.bookmarkState.isEmpty)
        XCTAssertEqual(doc.text, "a\nb\nc")

        // Clearing an already-empty state is a no-op, matching validation.
        XCTAssertFalse(controller.performCommand(identifier: "bookmark-clear-all"))
    }

    func testPerformCommandAppliesTextAndBookmarkStateChangesTogether() throws {
        let (controller, _) = makeController()
        let doc = try XCTUnwrap(controller.tabStore.selectedDocument)
        let textView = try XCTUnwrap(controller.editorTextView)

        doc.replaceAllText(with: "alpha\nbeta")
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertTrue(controller.performCommand(identifier: "bookmark-toggle"))
        XCTAssertEqual(doc.bookmarkState.lines, [1])

        // A text-only command still runs through the same DocumentState path;
        // the bookmark must survive the edit and the text must change.
        textView.setSelectedRange(NSRange(location: 0, length: 5))
        XCTAssertTrue(controller.performCommand(identifier: "uppercase"))
        XCTAssertEqual(doc.text, "ALPHA\nbeta")
        XCTAssertEqual(doc.bookmarkState.lines, [1])
    }

    // MARK: - Live remapping

    func testRemapIsSkippedWhileThereAreNoBookmarks() {
        let (editor, document) = makeEditor("one\ntwo\nthree")
        XCTAssertEqual(editor.bookmarkRemapCount, 0)

        document.replaceCharacters(in: NSRange(location: 0, length: 0),
                                   with: "zero\n")
        XCTAssertEqual(editor.bookmarkRemapCount, 0,
                       "an edit with no bookmarks must not run the line-math remap")
        XCTAssertTrue(editor.bookmarkLines.isEmpty)

        // The skip defers syncing the model's text, not correctness: a bookmark
        // added afterwards still validates against the edited document.
        XCTAssertTrue(editor.toggleBookmark(atLine: 4))
        XCTAssertEqual(editor.bookmarkLines, [4])

        document.replaceCharacters(in: NSRange(location: 0, length: 0),
                                   with: "first\n")
        XCTAssertEqual(editor.bookmarkRemapCount, 1,
                       "once a bookmark exists, edits remap it again")
        XCTAssertEqual(editor.bookmarkLines, [5])
        XCTAssertEqual(document.bookmarkState.lines, [5])
    }

    func testInsertingTextAboveABookmarkedLineRemapsIt() {
        let (editor, document) = makeEditor("one\ntwo\nthree")
        XCTAssertTrue(editor.toggleBookmark(atLine: 3))
        XCTAssertEqual(editor.bookmarkLines, [3])

        // Edit the shared buffer, not the editor's model: the container's
        // NSTextStorage observer must remap the live bookmark.
        document.replaceCharacters(in: NSRange(location: 0, length: 0),
                                   with: "zero\n")

        XCTAssertEqual(document.text, "zero\none\ntwo\nthree")
        XCTAssertEqual(editor.bookmarkLines, [4],
                       "the bookmark follows 'three' down one line")
        XCTAssertEqual(document.bookmarkState.lines, [4],
                       "the remapped state is persisted back to the document")
        XCTAssertTrue(editor.ruler.isBookmarked(line: 4))
        XCTAssertFalse(editor.ruler.isBookmarked(line: 3))
    }

    func testMultiCaretEditPreservesABookmarkBetweenTheCarets() {
        let (editor, document) = makeEditor("one\ntwo\nthree")
        XCTAssertTrue(editor.toggleBookmark(atLine: 2))
        document.undoManager.removeAllActions()

        // Two distant carets: the start of line 1 and the start of line 3.
        editor.textView.setSelectedRange(NSRange(location: 0, length: 0))
        editor.placeAdditionalCaret(atCharacterIndex: 8)
        XCTAssertEqual(editor.multiCaretState.count, 2)

        editor.applyMultiCaretInsertion("X")

        XCTAssertEqual(document.text, "Xone\ntwo\nXthree")
        XCTAssertEqual(editor.bookmarkLines, [2],
                       "the bookmark between the carets must keep its line")
        XCTAssertEqual(document.bookmarkState.lines, [2],
                       "the surviving bookmark is still persisted")

        // The whole multi-caret action is one undo step, and the bookmark
        // follows the restored text.
        document.undoManager.undo()
        XCTAssertEqual(document.text, "one\ntwo\nthree")
        XCTAssertEqual(editor.bookmarkLines, [2])
    }

    // MARK: - Text menu wiring

    func testTextMenuHasBookmarkItemsWithKeyEquivalents() throws {
        let menu = HexpadAppDelegate().buildMainMenu()
        let textMenu = try XCTUnwrap(menu.item(withTitle: "Text")?.submenu)

        let bookmarkItems = textMenu.items.filter {
            $0.action == #selector(MainWindowController.performBookmarkCommand(withIdentifier:))
        }
        let expected = CommandRegistry.default.bookmarkCommands
        XCTAssertEqual(bookmarkItems.map(\.title), expected.map(\.title))
        XCTAssertEqual(bookmarkItems.map { $0.representedObject as? String },
                       expected.map(\.identifier))

        for item in bookmarkItems {
            XCTAssertNil(item.target, "bookmark commands resolve through the responder chain")
        }

        func item(_ identifier: String) -> NSMenuItem? {
            bookmarkItems.first { ($0.representedObject as? String) == identifier }
        }

        let toggle = try XCTUnwrap(item("bookmark-toggle"))
        XCTAssertEqual(toggle.keyEquivalent, EditorCommandBinding.f2)
        XCTAssertEqual(toggle.keyEquivalentModifierMask, [.command])

        let next = try XCTUnwrap(item("bookmark-next"))
        XCTAssertEqual(next.keyEquivalent, EditorCommandBinding.f2)
        XCTAssertEqual(next.keyEquivalentModifierMask, [])

        let previous = try XCTUnwrap(item("bookmark-prev"))
        XCTAssertEqual(previous.keyEquivalent, EditorCommandBinding.f2)
        XCTAssertEqual(previous.keyEquivalentModifierMask, [.shift])

        let clearAll = try XCTUnwrap(item("bookmark-clear-all"))
        XCTAssertEqual(clearAll.keyEquivalent, "",
                       "clear-all ships without a default chord")
    }

    // MARK: - Search > Bookmark wiring

    func testSearchMenuContainsTheWholeBookmarkGroup() throws {
        let menu = HexpadAppDelegate().buildMainMenu()
        let searchMenu = try XCTUnwrap(menu.item(withTitle: "Search")?.submenu)
        let bookmarkItem = try XCTUnwrap(searchMenu.item(withTitle: "Bookmark"))
        let bookmarkMenu = try XCTUnwrap(bookmarkItem.submenu)

        let items = bookmarkMenu.items.filter { !$0.isSeparatorItem }
        let expected = CommandRegistry.default.bookmarkCommands
        XCTAssertEqual(items.map(\.title), expected.map(\.title))
        XCTAssertEqual(items.map { $0.representedObject as? String },
                       expected.map(\.identifier))

        for item in items {
            XCTAssertNil(item.target, "bookmark commands resolve through the responder chain")
            XCTAssertEqual(item.action,
                           #selector(MainWindowController.performBookmarkCommand(withIdentifier:)))
        }
    }

    func testBookmarkedLineCommandsValidateAgainstBookmarksAndDocument() throws {
        let (controller, _) = makeController()
        let doc = try XCTUnwrap(controller.tabStore.selectedDocument)

        func item(_ identifier: String) -> NSMenuItem {
            let item = NSMenuItem(title: identifier,
                                  action: #selector(MainWindowController.performBookmarkCommand(withIdentifier:)),
                                  keyEquivalent: "")
            item.representedObject = identifier
            return item
        }

        doc.replaceAllText(with: "one\ntwo\nthree")
        doc.bookmarkState = BookmarkState()

        // No bookmarks: only Inverse is available, because the document has
        // lines to bookmark.
        XCTAssertFalse(controller.validateMenuItem(item("bookmark-cut-lines")))
        XCTAssertFalse(controller.validateMenuItem(item("bookmark-copy-lines")))
        XCTAssertFalse(controller.validateMenuItem(item("bookmark-paste-replace-lines")))
        XCTAssertFalse(controller.validateMenuItem(item("bookmark-remove-lines")))
        XCTAssertTrue(controller.validateMenuItem(item("bookmark-inverse")))

        doc.bookmarkState = BookmarkState(bookmarks: [Bookmark(line: 2)])
        XCTAssertTrue(controller.validateMenuItem(item("bookmark-cut-lines")))
        XCTAssertTrue(controller.validateMenuItem(item("bookmark-copy-lines")))
        XCTAssertTrue(controller.validateMenuItem(item("bookmark-paste-replace-lines")))
        XCTAssertTrue(controller.validateMenuItem(item("bookmark-remove-lines")))
        XCTAssertTrue(controller.validateMenuItem(item("bookmark-inverse")))

        // Inverse needs a non-empty document; the bookmark commands still need
        // bookmarks (which an empty document cannot have).
        doc.replaceAllText(with: "")
        doc.bookmarkState = BookmarkState()
        XCTAssertFalse(controller.validateMenuItem(item("bookmark-inverse")))
    }
}
