import XCTest
import AppKit
@testable import Hexpad
@testable import HexpadKit

/// Clone to Other View must carry the metadata that decides how the next save
/// serializes the buffer. Dropping the EOL style rewrites CRLF/CR files as LF;
/// dropping the language loses highlighting and swaps the comment prefix;
/// dropping a pending "Convert to" silently saves the old bytes.
final class TestCloneFieldCopyTests: XCTestCase {

    // MARK: - The three regression fields

    func testCloneCopiesLanguage() {
        let doc = DocumentModel(text: "print('hi')\n")
        doc.setLanguage("Python")

        let clone = DocumentModel(cloneOf: doc)

        XCTAssertEqual(clone.language, "Python")
    }

    func testCloneCopiesEOLStyle() {
        for style in ["CRLF", "CR", "LF"] {
            // The editor buffer is LF-only; the style lives on the model and is
            // applied on save. A nil EOL would re-detect "LF" from this text.
            let doc = DocumentModel(text: "a\nb\nc", eolType: style)
            let clone = DocumentModel(cloneOf: doc)
            XCTAssertEqual(clone.eolType, style, "EOL style \(style) must survive the clone")
        }
    }

    func testCloneCopiesPendingEOLConversion() {
        let doc = DocumentModel(text: "a\nb")
        doc.convertEOL(to: "CRLF")
        XCTAssertTrue(doc.hasPendingSaveConversion)

        let clone = DocumentModel(cloneOf: doc)

        XCTAssertEqual(clone.eolType, "CRLF")
        XCTAssertTrue(clone.hasPendingSaveConversion, "pending conversion must not be dropped")
        XCTAssertTrue(clone.unsavedChanges, "a pending conversion keeps the clone dirty")
    }

    func testCloneCopiesPendingEncodingConversion() throws {
        let doc = DocumentModel(text: "plain ascii", filePath: URL(fileURLWithPath: "/tmp/clone-encoding.txt"))
        try doc.convertEncoding(to: "UTF-16")
        XCTAssertTrue(doc.hasPendingSaveConversion)

        let clone = DocumentModel(cloneOf: doc)

        XCTAssertEqual(clone.saveEncoding, doc.saveEncoding)
        XCTAssertTrue(clone.hasPendingSaveConversion)
        XCTAssertTrue(clone.unsavedChanges)
    }

    func testCloneCopiesKeepsBOM() {
        let doc = DocumentModel(text: "hello", filePath: URL(fileURLWithPath: "/tmp/clone-bom.txt"))
        doc.keepsBOM = true

        let clone = DocumentModel(cloneOf: doc)

        XCTAssertTrue(clone.keepsBOM)
    }

    // MARK: - Existing clone behavior stays intact

    func testClonePreservesOtherFieldsAndFreshIdentity() {
        let path = URL(fileURLWithPath: "/tmp/clone-fields.txt")
        let doc = DocumentModel(text: "clone me\n", filePath: path, eolType: "CRLF")
        doc.setLanguage("Swift")
        doc.keepsBOM = true
        doc.setReadOnly(true)
        doc.tabColorIndex = 3
        doc.wordWrapEnabled = true
        doc.zoomScale = 1.5
        doc.caretRange = NSRange(location: 4, length: 2)
        doc.setModified(true)

        let clone = DocumentModel(cloneOf: doc)

        XCTAssertEqual(clone.text, doc.text)
        XCTAssertEqual(clone.filePath, path, "same file")
        XCTAssertEqual(clone.language, "Swift")
        XCTAssertEqual(clone.eolType, "CRLF")
        XCTAssertTrue(clone.keepsBOM)
        XCTAssertTrue(clone.isReadOnly)
        XCTAssertEqual(clone.tabColorIndex, 3)
        XCTAssertTrue(clone.wordWrapEnabled)
        XCTAssertEqual(clone.zoomScale, 1.5)
        XCTAssertTrue(clone.unsavedChanges, "dirty state copies")
        XCTAssertNotEqual(clone.id, doc.id, "fresh identity")
        XCTAssertFalse(clone.undoManager === doc.undoManager, "independent undo stack")
        XCTAssertEqual(clone.caretRange.location, 0, "live caret does not copy")
    }

    // MARK: - Wiring: the menu action uses the same copy initializer

    func testCloneToOtherViewCarriesFieldsIntoOtherGroup() throws {
        let window = MainWindow()
        let controller = MainWindowController(window: window)
        window.contentViewController = controller
        _ = controller.view
        controller.openSplitView()

        let doc = DocumentModel(text: "let x = 1\n",
                                filePath: URL(fileURLWithPath: "/tmp/clone-wiring.swift"),
                                eolType: "CRLF")
        doc.setLanguage("Swift")
        doc.convertEOL(to: "CR")
        controller.tabStore.documents = [doc]
        controller.tabStore.selectedIndex = 0

        controller.cloneDocumentToOtherView(nil)

        let secondary = try XCTUnwrap(controller.allPanes.first { $0.group == .secondary }?.tabStore)
        let clone = try XCTUnwrap(secondary.documents.first)
        XCTAssertEqual(clone.language, "Swift")
        XCTAssertEqual(clone.eolType, "CR")
        XCTAssertTrue(clone.hasPendingSaveConversion)
        XCTAssertNotIdentical(clone, doc)
    }
}
