import XCTest
import AppKit
import HexpadKit
@testable import Hexpad

/// Wiring tests for per-document editor state. The model side
/// (`DocumentEditorState`) is covered in HexpadKit; these tests drive the real
/// `EditorContainer` and assert that binding a tab captures the outgoing state
/// and applies the incoming state instead of leaking the previous tab's caret.
final class EditorStatePersistenceTests: XCTestCase {

    /// Long enough that the caret offset 50 exists and the clip view has room
    /// to scroll.
    private let longText = (0..<200).map { "line \($0)" }.joined(separator: "\n")

    private func makeEditor(_ text: String) -> (editor: EditorContainer, document: DocumentModel) {
        let document = DocumentModel(text: text)
        let editor = EditorContainer()
        editor.bind(to: document)
        return (editor, document)
    }

    private func makeController() -> (controller: MainWindowController, window: MainWindow) {
        let window = MainWindow()
        let controller = MainWindowController(window: window)
        window.contentViewController = controller
        _ = controller.view // loadView + viewDidLoad; creates the first tab
        return (controller, window)
    }

    // MARK: - Caret

    func testCaretIsCapturedPerDocumentAndDoesNotLeakAcrossTabs() {
        let (editor, docA) = makeEditor(longText)
        let docB = DocumentModel(text: longText)
        XCTAssertEqual(docB.caretRange, NSRange(location: 0, length: 0))

        editor.textView.setSelectedRange(NSRange(location: 50, length: 0))
        XCTAssertEqual(editor.multiCaretState.primaryCaret, NSRange(location: 50, length: 0))

        editor.bind(to: docB)

        XCTAssertEqual(docA.caretRange, NSRange(location: 50, length: 0),
                       "unbinding must capture the outgoing tab's caret")
        XCTAssertEqual(docB.caretRange, NSRange(location: 0, length: 0),
                       "the incoming tab keeps its own persisted caret")
        XCTAssertEqual(editor.textView.selectedRange, NSRange(location: 0, length: 0),
                       "the previous tab's caret must not leak into the new tab")
        XCTAssertEqual(editor.multiCaretState.primaryCaret, NSRange(location: 0, length: 0))

        editor.bind(to: docA)

        XCTAssertEqual(editor.textView.selectedRange, NSRange(location: 50, length: 0),
                       "returning to a tab restores its caret")
        XCTAssertEqual(editor.multiCaretState.primaryCaret, NSRange(location: 50, length: 0))
        XCTAssertEqual(docA.caretRange, NSRange(location: 50, length: 0))
    }

    func testRestoredCaretIsClampedToTheIncomingDocument() {
        let (editor, _) = makeEditor("short")
        let document = DocumentModel(text: "short")
        document.caretRange = NSRange(location: 500, length: 40)

        editor.bind(to: document)

        XCTAssertEqual(document.caretRange, NSRange(location: 500, length: 40),
                       "bind only clamps what it applies; the stored value is untouched")
        XCTAssertEqual(editor.textView.selectedRange, NSRange(location: 5, length: 0),
                       "a stale session caret cannot index past the buffer")
        XCTAssertEqual(editor.multiCaretState.primaryCaret, NSRange(location: 5, length: 0))
    }

    // MARK: - Scroll, wrap and zoom

    func testScrollWrapAndZoomAreCapturedAndRestoredOnRebind() {
        let (editor, docA) = makeEditor(longText)
        let docB = DocumentModel(text: longText)

        // Give the container a real viewport and lay the document out so the
        // clip view can actually scroll.
        editor.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
        editor.layout()
        editor.textView.layoutManager?.ensureLayout(for: editor.textView.textContainer!)

        editor.setWordWrapEnabled(true)
        editor.setZoomScale(1.5)
        editor.layout()

        editor.scrollView.contentView.scroll(to: CGPoint(x: 0, y: 240))
        editor.scrollView.reflectScrolledClipView(editor.scrollView.contentView)
        XCTAssertEqual(editor.scrollView.contentView.bounds.origin.y, 240, accuracy: 1)

        editor.bind(to: docB)
        editor.layout()

        XCTAssertEqual(docA.scrollOffset.y, 240, accuracy: 1,
                       "unbinding captures the scroll origin")
        XCTAssertTrue(docA.wordWrapEnabled, "unbinding captures word wrap")
        XCTAssertEqual(docA.zoomScale, 1.5, accuracy: 0.0001, "unbinding captures zoom")

        XCTAssertEqual(editor.scrollView.contentView.bounds.origin.y, 0, accuracy: 1,
                       "a fresh tab starts at its own scroll position")
        XCTAssertFalse(editor.isWordWrapEnabled, "a fresh tab starts unwrapped")
        XCTAssertEqual(editor.zoomScale, 1.0, accuracy: 0.0001,
                       "a fresh tab starts at 100% zoom")

        editor.bind(to: docA)
        editor.layout()

        XCTAssertEqual(editor.scrollView.contentView.bounds.origin.y, 240, accuracy: 1,
                       "returning to a tab restores its scroll origin")
        XCTAssertTrue(editor.isWordWrapEnabled, "returning to a tab restores word wrap")
        XCTAssertEqual(editor.zoomScale, 1.5, accuracy: 0.0001,
                       "returning to a tab restores zoom")
    }

    // MARK: - Command write-through

    func testToggleWordWrapWritesThroughToTheSelectedDocument() throws {
        let (controller, _) = makeController()
        let document = try XCTUnwrap(controller.tabStore.selectedDocument)
        let textView = try XCTUnwrap(controller.editorTextView)

        XCTAssertFalse(document.wordWrapEnabled)
        XCTAssertTrue(textView.isHorizontallyResizable)

        controller.toggleWordWrap()

        XCTAssertTrue(document.wordWrapEnabled,
                      "the menu command must persist, not just mutate the view")
        XCTAssertFalse(textView.isHorizontallyResizable)

        controller.toggleWordWrap()

        XCTAssertFalse(document.wordWrapEnabled)
        XCTAssertTrue(textView.isHorizontallyResizable)
    }

    func testZoomCommandsWriteThroughToTheSelectedDocument() throws {
        let (controller, _) = makeController()
        let document = try XCTUnwrap(controller.tabStore.selectedDocument)
        let textView = try XCTUnwrap(controller.editorTextView)

        XCTAssertEqual(document.zoomScale, 1.0, accuracy: 0.0001)

        controller.zoomIn()

        XCTAssertEqual(textView.font?.pointSize, 14)
        XCTAssertEqual(document.zoomScale,
                       14 / EditorContainer.defaultFontSize,
                       accuracy: 0.0001,
                       "zoom-in must persist, not just mutate the view")

        controller.resetZoom()

        XCTAssertEqual(textView.font?.pointSize, EditorContainer.defaultFontSize)
        XCTAssertEqual(document.zoomScale, 1.0, accuracy: 0.0001)

        controller.zoomOut()

        XCTAssertEqual(textView.font?.pointSize, EditorContainer.defaultFontSize - 1)
        XCTAssertEqual(document.zoomScale,
                       (EditorContainer.defaultFontSize - 1) / EditorContainer.defaultFontSize,
                       accuracy: 0.0001,
                       "zoom-out must persist, not just mutate the view")
    }

    // MARK: - Tab switching through the controller

    func testSwitchingTabsThroughTheControllerKeepsEachDocumentsCaret() throws {
        let (controller, _) = makeController()
        let docA = try XCTUnwrap(controller.tabStore.selectedDocument)
        docA.replaceAllText(with: longText)
        let textView = try XCTUnwrap(controller.editorTextView)
        textView.setSelectedRange(NSRange(location: 50, length: 0))

        controller.addNewTab()
        let docB = try XCTUnwrap(controller.tabStore.selectedDocument)
        XCTAssertFalse(docB === docA)
        XCTAssertEqual(docB.caretRange, NSRange(location: 0, length: 0))
        XCTAssertEqual(textView.selectedRange, NSRange(location: 0, length: 0),
                       "the new tab must not inherit the previous tab's caret")

        controller.selectTab(at: 0)

        XCTAssertEqual(textView.selectedRange, NSRange(location: 50, length: 0),
                       "switching back restores the first tab's caret")
    }

    // MARK: - Session save

    func testSaveSessionCapturesTheLiveCaret() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hexpad-editor-state-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        SessionStore.overrideDirectory = directory
        defer {
            SessionStore.overrideDirectory = nil
            try? FileManager.default.removeItem(at: directory)
        }

        let (controller, _) = makeController()
        let document = try XCTUnwrap(controller.tabStore.selectedDocument)
        document.replaceAllText(with: longText)
        let textView = try XCTUnwrap(controller.editorTextView)
        textView.setSelectedRange(NSRange(location: 50, length: 0))

        controller.saveSession()

        let restored = try XCTUnwrap(SessionStore.restore())
        let restoredDocument = try XCTUnwrap(restored.tabs.documents.first)
        XCTAssertEqual(restoredDocument.caretRange, NSRange(location: 50, length: 0),
                       "saving must flush the live editor state before writing")
    }
}
