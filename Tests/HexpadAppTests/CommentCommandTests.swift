import XCTest
import AppKit
import HexpadKit
@testable import Hexpad

/// P17f-1: end-to-end coverage for per-language line comments. The controller
/// owns one registry for the whole window, so the `toggle-line-comment` prefix
/// must follow the focused document's language (controller setup mirrors
/// `BraceMenuTests`).
final class CommentCommandTests: XCTestCase {

    private func makeController() -> MainWindowController {
        let window = MainWindow()
        let controller = MainWindowController(window: window)
        window.contentViewController = controller
        _ = controller.view // loadView + viewDidLoad; creates the first tab
        return controller
    }

    /// Sets text and language on the focused document, then rebinds — the same
    /// path `MainWindowController.setLanguage(_:)` takes in the app.
    @discardableResult
    private func useLanguage(_ language: Language,
                             text: String,
                             in controller: MainWindowController) throws -> DocumentModel {
        let document = try XCTUnwrap(controller.tabStore.selectedDocument)
        document.replaceAllText(with: text)
        document.setLanguage(language.rawValue)
        controller.updateEditor()
        return document
    }

    func testPythonDocumentTogglesHashPrefix() throws {
        let controller = makeController()
        let document = try useLanguage(.python, text: "alpha\nbeta", in: controller)
        let textView = try XCTUnwrap(controller.editorTextView)
        textView.setSelectedRange(NSRange(location: 0, length: 0))

        XCTAssertTrue(controller.performCommand(identifier: "toggle-line-comment"))
        // Python's line-prefix metadata is `#` (no trailing space).
        XCTAssertEqual(document.text, "#alpha\nbeta")

        // Toggling again strips it.
        XCTAssertTrue(controller.performCommand(identifier: "toggle-line-comment"))
        XCTAssertEqual(document.text, "alpha\nbeta")
    }

    func testSwiftDocumentTogglesDoubleSlashPrefix() throws {
        let controller = makeController()
        let document = try useLanguage(.swift, text: "alpha\nbeta", in: controller)
        let textView = try XCTUnwrap(controller.editorTextView)
        textView.setSelectedRange(NSRange(location: 0, length: 0))

        XCTAssertTrue(controller.performCommand(identifier: "toggle-line-comment"))
        XCTAssertEqual(document.text, "//alpha\nbeta")
    }

    /// The shared registry must retarget when the same document's language
    /// changes, not only when a new tab is bound.
    func testLanguageChangeRetargetsCommentPrefix() throws {
        let controller = makeController()
        let document = try useLanguage(.python, text: "alpha", in: controller)
        let textView = try XCTUnwrap(controller.editorTextView)
        textView.setSelectedRange(NSRange(location: 0, length: 0))

        XCTAssertTrue(controller.performCommand(identifier: "toggle-line-comment"))
        XCTAssertEqual(document.text, "#alpha")

        try useLanguage(.swift, text: "alpha", in: controller)
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertTrue(controller.performCommand(identifier: "toggle-line-comment"))
        XCTAssertEqual(document.text, "//alpha")
    }
}
